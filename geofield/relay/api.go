package main

import (
	"compress/gzip"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
)

// Лимит тела запроса: спутниковые пакеты — сотни КБ (ТЗ 10.1); 8 МиБ —
// щедрый потолок против случайного/злонамеренного гиганта.
const maxBodyBytes = 8 << 20

// Лимит РАСПАКОВАННОГО тела: gzip-бомба в 8 МиБ разворачивается в гигабайты,
// MaxBytesReader ограничивает только сжатый поток.
const maxDecompressedBytes = 64 << 20

const defaultPullLimit = 500
const maxPullLimit = 5000

// Потолок мутаций в одном пакете: остальное режется клиентским пакетайзером
// задолго до этой цифры; здесь — защита от сломанного клиента.
const maxChangesPerPush = 10000

// pushRequest — пакет мутаций от устройства (sync-protocol.md §3.1).
type pushRequest struct {
	DeviceID string   `json:"device_id"`
	Changes  []Change `json:"changes"`
}

type pushResponse struct {
	BatchID    string   `json:"batch_id"`
	Accepted   []string `json:"accepted"`
	Duplicates []string `json:"duplicates"`
	LastSeq    int64    `json:"last_seq"`
}

type pullResponse struct {
	Changes    []StoredChange `json:"changes"`
	NextCursor int64          `json:"next_cursor"`
	HasMore    bool           `json:"has_more"`
}

type server struct {
	journal *Journal
	token   string
}

func newMux(s *server) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("POST /v1/push", s.auth(s.handlePush))
	mux.HandleFunc("GET /v1/pull", s.auth(s.handlePull))
	return mux
}

// auth — Bearer-токен, сравнение постоянного времени.
func (s *server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(got), []byte(s.token)) != 1 {
			jsonError(w, http.StatusUnauthorized, "нет или неверный токен")
			return
		}
		next(w, r)
	}
}

func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	// Единственный неаутентифицированный маршрут: без last_seq —
	// интенсивность работ партии не для посторонних глаз.
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handlePush(w http.ResponseWriter, r *http.Request) {
	body := http.MaxBytesReader(w, r.Body, maxBodyBytes)
	var reader io.Reader = body
	// Пакеты идут сжатыми (§3.1); поддерживаем gzip Content-Encoding.
	if strings.EqualFold(r.Header.Get("Content-Encoding"), "gzip") {
		gz, err := gzip.NewReader(body)
		if err != nil {
			jsonError(w, http.StatusBadRequest, "битый gzip: "+err.Error())
			return
		}
		defer gz.Close()
		reader = gz
	}

	data, err := io.ReadAll(io.LimitReader(reader, maxDecompressedBytes+1))
	if err != nil {
		jsonError(w, http.StatusBadRequest, "чтение тела: "+err.Error())
		return
	}
	if len(data) > maxDecompressedBytes {
		jsonError(w, http.StatusRequestEntityTooLarge, "распакованное тело больше лимита")
		return
	}

	// Неизвестные поля верхнего уровня терпимы: более новый клиент не должен
	// намертво блокироваться о ещё не обновлённый relay (эволюция протокола).
	var req pushRequest
	if err := json.Unmarshal(data, &req); err != nil {
		jsonError(w, http.StatusBadRequest, "битый JSON: "+err.Error())
		return
	}
	if req.DeviceID == "" {
		jsonError(w, http.StatusUnprocessableEntity, "device_id обязателен")
		return
	}
	if len(req.Changes) == 0 {
		jsonError(w, http.StatusUnprocessableEntity, "пустой пакет")
		return
	}
	if len(req.Changes) > maxChangesPerPush {
		jsonError(w, http.StatusUnprocessableEntity,
			fmt.Sprintf("пакет больше %d мутаций", maxChangesPerPush))
		return
	}
	// Пакет атомарен: одна невалидная мутация — отказ целиком (клиенту
	// проще возобновляться, чем сшивать частично принятые пакеты).
	for i := range req.Changes {
		if err := req.Changes[i].Validate(); err != nil {
			jsonError(w, http.StatusUnprocessableEntity,
				fmt.Sprintf("мутация №%d (%s): %v", i, req.Changes[i].ChangeID, err))
			return
		}
	}

	accepted, duplicates, err := s.journal.Append(req.DeviceID, req.Changes)
	if err != nil {
		log.Printf("push: отказ записи журнала: %v", err)
		jsonError(w, http.StatusInternalServerError, "запись не удалась, повторите пакет")
		return
	}
	writeJSON(w, http.StatusOK, pushResponse{
		BatchID:    newBatchID(),
		Accepted:   accepted,
		Duplicates: duplicates,
		LastSeq:    s.journal.LastSeq(),
	})
}

func (s *server) handlePull(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	deviceID := q.Get("device_id")
	if deviceID == "" {
		jsonError(w, http.StatusUnprocessableEntity, "device_id обязателен")
		return
	}
	cursor := int64(0)
	if c := q.Get("cursor"); c != "" {
		v, err := strconv.ParseInt(c, 10, 64)
		if err != nil || v < 0 {
			jsonError(w, http.StatusBadRequest, "cursor — неотрицательное число")
			return
		}
		cursor = v
	}
	limit := defaultPullLimit
	if l := q.Get("limit"); l != "" {
		v, err := strconv.Atoi(l)
		if err != nil || v < 1 {
			jsonError(w, http.StatusBadRequest, "limit — положительное число")
			return
		}
		limit = min(v, maxPullLimit)
	}

	changes, next := s.journal.List(cursor, limit, deviceID)
	writeJSON(w, http.StatusOK, pullResponse{
		Changes:    changes,
		NextCursor: next,
		HasMore:    next < s.journal.LastSeq(),
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("ответ не отправлен: %v", err)
	}
}

func jsonError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func newBatchID() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		// crypto/rand на Linux не отказывает; на всякий случай — не молчим.
		panic(fmt.Sprintf("нет источника случайности: %v", err))
	}
	return "b_" + hex.EncodeToString(b)
}
