package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
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
	lastSeq int64
	seen    map[string]struct{} // change_id → принят (идемпотентность)
	items   []StoredChange      // упорядочены по seq
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
	for sc.Scan() {
		line++
		b := sc.Bytes()
		if len(b) == 0 {
			continue
		}
		var rec StoredChange
		if err := json.Unmarshal(b, &rec); err != nil {
			// Обрыв на последней строке (падение при записи) допустим и
			// отбрасывается; порча в середине журнала — стоп, нужен разбор.
			if !sc.Scan() {
				break
			}
			f.Close()
			return nil, fmt.Errorf("журнал повреждён на строке %d: %w", line, err)
		}
		if rec.Seq <= j.lastSeq {
			f.Close()
			return nil, fmt.Errorf("журнал: seq %d не монотонен (строка %d)", rec.Seq, line)
		}
		j.lastSeq = rec.Seq
		j.seen[rec.ChangeID] = struct{}{}
		j.items = append(j.items, rec)
	}
	if err := sc.Err(); err != nil {
		f.Close()
		return nil, fmt.Errorf("чтение журнала: %w", err)
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

	now := time.Now().UTC().Format(time.RFC3339)
	var buf []byte
	var pending []StoredChange
	for _, c := range changes {
		if _, dup := j.seen[c.ChangeID]; dup {
			duplicates = append(duplicates, c.ChangeID)
			continue
		}
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
	if _, err = j.f.Write(buf); err != nil {
		return nil, nil, fmt.Errorf("запись журнала: %w", err)
	}
	if err = j.f.Sync(); err != nil {
		return nil, nil, fmt.Errorf("fsync журнала: %w", err)
	}
	for _, rec := range pending {
		j.lastSeq = rec.Seq
		j.seen[rec.ChangeID] = struct{}{}
		j.items = append(j.items, rec)
		accepted = append(accepted, rec.ChangeID)
	}
	return accepted, duplicates, nil
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
