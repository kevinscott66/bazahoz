package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"sync"
	"time"
)

// Change — одна мутация журнала изменений (sync-protocol.md §1).
type Change struct {
	ChangeID    string          `json:"change_id"`
	EntityTable string          `json:"entity_table"`
	EntityID    string          `json:"entity_id"`
	Op          string          `json:"op"` // insert | update | delete
	Payload     json.RawMessage `json:"payload"`
	AuthorID    string          `json:"author_id"`
	LogicalTS   string          `json:"logical_ts"`
}

// StoredChange — принятая мутация с серверным порядковым номером (курсор PULL).
type StoredChange struct {
	Seq        int64  `json:"seq"`
	DeviceID   string `json:"device_id"`
	ReceivedAt string `json:"received_at"`
	Change
}

// Validate — валидация мутации до приёма. Пакет с невалидной мутацией
// отвергается целиком (приём атомарен, возобновление остаётся простым).
func (c *Change) Validate() error {
	switch {
	case c.ChangeID == "":
		return errors.New("change_id пуст")
	case c.EntityTable == "":
		return errors.New("entity_table пуст")
	case c.EntityID == "":
		return errors.New("entity_id пуст")
	case c.Op != "insert" && c.Op != "update" && c.Op != "delete":
		return fmt.Errorf("op %q не из insert|update|delete", c.Op)
	case c.AuthorID == "":
		// Обязателен по контракту §1: нужен для разрыва ничьей HLC (§4)
		// и атрибуции в record_history/conflicts (§5).
		return errors.New("author_id пуст")
	case c.LogicalTS == "":
		return errors.New("logical_ts пуст")
	case len(c.Payload) == 0 || !json.Valid(c.Payload):
		return errors.New("payload не является корректным JSON")
	}
	return nil
}

// Journal — durable-хранилище relay: append-only файл JSONL + индекс в памяти.
// При старте журнал реплеится с диска. Запись пакета — одним append с fsync.
type Journal struct {
	mu      sync.Mutex
	f       *os.File
	path    string
	size    int64 // подтверждённый размер файла (для отката сбойной записи)
	lastSeq int64
	seen    map[string]struct{} // change_id → принят (идемпотентность)
	items   []StoredChange      // упорядочены по seq
	broken  bool                // файл в неопределённом состоянии — приём закрыт
}

// OpenJournal открывает (или создаёт) журнал и реплеит его содержимое.
func OpenJournal(path string) (*Journal, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|os.O_APPEND, 0o600)
	if err != nil {
		return nil, fmt.Errorf("открытие журнала: %w", err)
	}
	j := &Journal{f: f, path: path, seen: make(map[string]struct{})}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 16<<20)
	line := 0
	var goodBytes int64
	for sc.Scan() {
		line++
		b := sc.Bytes()
		if len(b) == 0 {
			goodBytes += 1 // пустая строка + \n
			continue
		}
		var rec StoredChange
		if err := json.Unmarshal(b, &rec); err != nil {
			// Обрыв на последней строке (падение при записи) допустим и
			// отбрасывается — но НЕ молча: если это была уже подтверждённая
			// клиенту запись (битый сектор и т.п.), след останется в логе.
			if !sc.Scan() {
				log.Printf("журнал: последняя строка %d отброшена как оборванная/битая: %v", line, err)
				break
			}
			f.Close()
			return nil, fmt.Errorf("журнал повреждён на строке %d: %w", line, err)
		}
		if _, dup := j.seen[rec.ChangeID]; dup {
			// Повтор change_id на диске возможен после сбоя записи и ретрая
			// пакета (см. Append) — реплей идемпотентен: первую копию храним,
			// повтор пропускаем с предупреждением.
			log.Printf("журнал: строка %d — повтор change_id %s, пропущена", line, rec.ChangeID)
			goodBytes += int64(len(b)) + 1
			continue
		}
		if rec.Seq <= j.lastSeq {
			f.Close()
			return nil, fmt.Errorf("журнал: seq %d не монотонен (строка %d)", rec.Seq, line)
		}
		j.lastSeq = rec.Seq
		j.seen[rec.ChangeID] = struct{}{}
		j.items = append(j.items, rec)
		goodBytes += int64(len(b)) + 1
	}
	if err := sc.Err(); err != nil {
		f.Close()
		return nil, fmt.Errorf("чтение журнала: %w", err)
	}
	j.size = goodBytes
	// Отброшенный хвост отрезаем сразу, чтобы следующий append не создал
	// файл со «склеенной» строкой.
	if st, err := f.Stat(); err == nil && st.Size() > goodBytes {
		if err := f.Truncate(goodBytes); err != nil {
			f.Close()
			return nil, fmt.Errorf("усечение оборванного хвоста: %w", err)
		}
	}
	return j, nil
}

func (j *Journal) Close() error { return j.f.Close() }

// Append принимает пакет мутаций устройства. Дубликаты (по change_id)
// пропускаются без ошибки — повторная доставка пакета безопасна (§8.2).
// Возвращает принятые change_id и дубликаты.
func (j *Journal) Append(deviceID string, changes []Change) (accepted, duplicates []string, err error) {
	j.mu.Lock()
	defer j.mu.Unlock()

	if j.broken {
		return nil, nil, errors.New("журнал в неопределённом состоянии после сбоя записи — нужен рестарт relay")
	}

	now := time.Now().UTC().Format(time.RFC3339)
	var buf []byte
	var pending []StoredChange
	inBatch := make(map[string]struct{}) // дедуп внутри одного пакета
	for _, c := range changes {
		_, dupSeen := j.seen[c.ChangeID]
		_, dupBatch := inBatch[c.ChangeID]
		if dupSeen || dupBatch {
			duplicates = append(duplicates, c.ChangeID)
			continue
		}
		inBatch[c.ChangeID] = struct{}{}
		rec := StoredChange{
			Seq:        j.lastSeq + int64(len(pending)) + 1,
			DeviceID:   deviceID,
			ReceivedAt: now,
			Change:     c,
		}
		line, mErr := json.Marshal(rec)
		if mErr != nil {
			return nil, nil, fmt.Errorf("сериализация: %w", mErr)
		}
		buf = append(buf, line...)
		buf = append(buf, '\n')
		pending = append(pending, rec)
	}
	if len(pending) == 0 {
		return nil, duplicates, nil
	}
	// Одна запись + fsync на пакет: либо пакет на диске целиком, либо
	// (при падении) его хвост отбросится реплеем как оборванная строка.
	// При ошибке Write/Sync часть байтов могла лечь на диск — откатываем
	// файл к подтверждённому размеру, иначе ретрай пакета продублирует
	// строки с теми же seq и реплей после рестарта откажет.
	if _, err = j.f.Write(buf); err != nil {
		j.rollback()
		return nil, nil, fmt.Errorf("запись журнала: %w", err)
	}
	if err = j.f.Sync(); err != nil {
		j.rollback()
		return nil, nil, fmt.Errorf("fsync журнала: %w", err)
	}
	j.size += int64(len(buf))
	for _, rec := range pending {
		j.lastSeq = rec.Seq
		j.seen[rec.ChangeID] = struct{}{}
		j.items = append(j.items, rec)
		accepted = append(accepted, rec.ChangeID)
	}
	return accepted, duplicates, nil
}

// rollback пытается срезать файл до последнего подтверждённого размера.
// Не вышло — журнал помечается сломанным и приём закрывается (данные на
// диске целы, но их граница неизвестна; реплей при рестарте разберётся —
// повторы change_id он пропускает).
func (j *Journal) rollback() {
	if err := j.f.Truncate(j.size); err != nil {
		log.Printf("журнал: откат до %d байт не удался (%v) — приём закрыт до рестарта", j.size, err)
		j.broken = true
		return
	}
	if err := j.f.Sync(); err != nil {
		log.Printf("журнал: fsync после отката не удался (%v) — приём закрыт до рестарта", err)
		j.broken = true
	}
}

// List отдаёт мутации с seq > cursor, кроме мутаций самого запрашивающего
// устройства (они у него уже есть), не более limit. Возвращает и nextCursor —
// seq последней ПРОСМОТРЕННОЙ записи (не последней отданной), чтобы пропуски
// чужого устройства не перечитывались вечно.
func (j *Journal) List(cursor int64, limit int, excludeDevice string) (out []StoredChange, nextCursor int64) {
	j.mu.Lock()
	defer j.mu.Unlock()

	nextCursor = cursor
	for _, rec := range j.items {
		if rec.Seq <= cursor {
			continue
		}
		if len(out) >= limit {
			break
		}
		nextCursor = rec.Seq
		if rec.DeviceID == excludeDevice {
			continue
		}
		out = append(out, rec)
	}
	return out, nextCursor
}

// LastSeq — текущий серверный курсор (для диагностики).
func (j *Journal) LastSeq() int64 {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.lastSeq
}
