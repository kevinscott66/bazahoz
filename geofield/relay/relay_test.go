package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func testServer(t *testing.T) (*httptest.Server, *Journal, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	j, err := OpenJournal(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { j.Close() })
	ts := httptest.NewServer(newMux(&server{journal: j, token: "secret"}))
	t.Cleanup(ts.Close)
	return ts, j, path
}

func change(id, entity string) Change {
	return Change{
		ChangeID:    id,
		EntityTable: "samples",
		EntityID:    entity,
		Op:          "insert",
		Payload:     json.RawMessage(`{"sample_number":"SUZ-00001"}`),
		AuthorID:    "geo-1",
		LogicalTS:   "2026-07-02T10:00:00Z",
	}
}

func doPush(t *testing.T, ts *httptest.Server, token, device string, gzipBody bool, changes ...Change) (*http.Response, pushResponse) {
	t.Helper()
	body, _ := json.Marshal(pushRequest{DeviceID: device, Changes: changes})
	var buf bytes.Buffer
	if gzipBody {
		gw := gzip.NewWriter(&buf)
		gw.Write(body)
		gw.Close()
	} else {
		buf.Write(body)
	}
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/push", &buf)
	req.Header.Set("Authorization", "Bearer "+token)
	if gzipBody {
		req.Header.Set("Content-Encoding", "gzip")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var pr pushResponse
	if resp.StatusCode == http.StatusOK {
		json.NewDecoder(resp.Body).Decode(&pr)
	}
	resp.Body.Close()
	return resp, pr
}

func doPull(t *testing.T, ts *httptest.Server, device string, cursor int64, limit int) pullResponse {
	t.Helper()
	url := fmt.Sprintf("%s/v1/pull?device_id=%s&cursor=%d", ts.URL, device, cursor)
	if limit > 0 {
		url += fmt.Sprintf("&limit=%d", limit)
	}
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("Authorization", "Bearer secret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("pull: статус %d", resp.StatusCode)
	}
	var pr pullResponse
	json.NewDecoder(resp.Body).Decode(&pr)
	return pr
}

func TestPushIdempotent(t *testing.T) {
	ts, _, _ := testServer(t)
	resp, pr := doPush(t, ts, "secret", "dev-a", false, change("c1", "e1"), change("c2", "e2"))
	if resp.StatusCode != http.StatusOK || len(pr.Accepted) != 2 {
		t.Fatalf("первый push: %d, accepted=%v", resp.StatusCode, pr.Accepted)
	}
	// Повторная доставка того же пакета — безопасна (§8.2).
	_, pr2 := doPush(t, ts, "secret", "dev-a", false, change("c1", "e1"), change("c2", "e2"))
	if len(pr2.Accepted) != 0 || len(pr2.Duplicates) != 2 {
		t.Fatalf("повтор: accepted=%v duplicates=%v", pr2.Accepted, pr2.Duplicates)
	}
	if pr2.LastSeq != 2 {
		t.Fatalf("last_seq=%d, ожидалось 2", pr2.LastSeq)
	}
}

func TestPullExcludesOwnDeviceAndResumes(t *testing.T) {
	ts, _, _ := testServer(t)
	doPush(t, ts, "secret", "dev-a", false, change("a1", "e1"), change("a2", "e2"))
	doPush(t, ts, "secret", "dev-b", false, change("b1", "e3"))

	// dev-b не получает своё, получает чужое.
	pr := doPull(t, ts, "dev-b", 0, 0)
	if len(pr.Changes) != 2 || pr.Changes[0].ChangeID != "a1" {
		t.Fatalf("dev-b получил %+v", pr.Changes)
	}
	// Возобновление с курсора: ничего нового — пусто, курсор стоит.
	pr2 := doPull(t, ts, "dev-b", pr.NextCursor, 0)
	if len(pr2.Changes) != 0 || pr2.HasMore {
		t.Fatalf("возобновление: %+v", pr2)
	}
	// dev-a видит только чужую b1 (свои a1/a2 пропущены, курсор проходит их).
	pra := doPull(t, ts, "dev-a", 0, 0)
	if len(pra.Changes) != 1 || pra.Changes[0].ChangeID != "b1" || pra.NextCursor != 3 {
		t.Fatalf("dev-a получил %+v next=%d", pra.Changes, pra.NextCursor)
	}
}

func TestPullPagination(t *testing.T) {
	ts, _, _ := testServer(t)
	var cs []Change
	for i := range 5 {
		cs = append(cs, change(fmt.Sprintf("c%d", i), fmt.Sprintf("e%d", i)))
	}
	doPush(t, ts, "secret", "dev-a", false, cs...)

	pr := doPull(t, ts, "dev-b", 0, 2)
	if len(pr.Changes) != 2 || !pr.HasMore {
		t.Fatalf("страница 1: %+v", pr)
	}
	pr2 := doPull(t, ts, "dev-b", pr.NextCursor, 2)
	pr3 := doPull(t, ts, "dev-b", pr2.NextCursor, 2)
	total := len(pr.Changes) + len(pr2.Changes) + len(pr3.Changes)
	if total != 5 || pr3.HasMore {
		t.Fatalf("всего %d, hasMore=%v", total, pr3.HasMore)
	}
}

func TestReplayAfterRestartAndTruncatedTail(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	j, err := OpenJournal(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := j.Append("dev-a", []Change{change("c1", "e1"), change("c2", "e2")}); err != nil {
		t.Fatal(err)
	}
	j.Close()

	// Имитация падения на середине записи: оборванная последняя строка.
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	f.WriteString(`{"seq":3,"device_id":"dev-a","chan`)
	f.Close()

	j2, err := OpenJournal(path)
	if err != nil {
		t.Fatalf("реплей с оборванным хвостом должен пройти: %v", err)
	}
	defer j2.Close()
	if j2.LastSeq() != 2 {
		t.Fatalf("last_seq=%d, ожидалось 2 (хвост отброшен)", j2.LastSeq())
	}
	// Дедуп пережил рестарт.
	_, dup, err := j2.Append("dev-a", []Change{change("c1", "e1")})
	if err != nil || len(dup) != 1 {
		t.Fatalf("дедуп после рестарта: dup=%v err=%v", dup, err)
	}
}

func TestAuthRequired(t *testing.T) {
	ts, _, _ := testServer(t)
	resp, _ := doPush(t, ts, "wrong", "dev-a", false, change("c1", "e1"))
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("статус %d, ожидался 401", resp.StatusCode)
	}
}

func TestGzipPush(t *testing.T) {
	ts, _, _ := testServer(t)
	resp, pr := doPush(t, ts, "secret", "dev-a", true, change("c1", "e1"))
	if resp.StatusCode != http.StatusOK || len(pr.Accepted) != 1 {
		t.Fatalf("gzip push: %d %+v", resp.StatusCode, pr)
	}
}

func TestValidationRejectsBatch(t *testing.T) {
	ts, j, _ := testServer(t)
	bad := change("c-bad", "e1")
	bad.Op = "explode"
	resp, _ := doPush(t, ts, "secret", "dev-a", false, change("c-ok", "e0"), bad)
	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("статус %d, ожидался 422", resp.StatusCode)
	}
	// Пакет атомарен: валидная мутация из битого пакета тоже не принята.
	if j.LastSeq() != 0 {
		t.Fatalf("битый пакет частично принят: last_seq=%d", j.LastSeq())
	}
}

func TestIntraBatchDuplicate(t *testing.T) {
	ts, j, _ := testServer(t)
	// Одна и та же мутация дважды в ОДНОМ пакете — принимается один раз.
	resp, pr := doPush(t, ts, "secret", "dev-a", false, change("c1", "e1"), change("c1", "e1"))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("статус %d", resp.StatusCode)
	}
	if len(pr.Accepted) != 1 || len(pr.Duplicates) != 1 {
		t.Fatalf("accepted=%v duplicates=%v", pr.Accepted, pr.Duplicates)
	}
	if j.LastSeq() != 1 {
		t.Fatalf("last_seq=%d, ожидалось 1", j.LastSeq())
	}
}

func TestAuthorIDRequired(t *testing.T) {
	ts, _, _ := testServer(t)
	c := change("c1", "e1")
	c.AuthorID = ""
	resp, _ := doPush(t, ts, "secret", "dev-a", false, c)
	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("статус %d, ожидался 422 (author_id обязателен)", resp.StatusCode)
	}
}

func TestUnknownTopLevelFieldTolerated(t *testing.T) {
	ts, _, _ := testServer(t)
	// Более новый клиент прислал лишнее поле — пакет не должен отвергаться.
	body := `{"device_id":"dev-a","client_version":"9.9","changes":[
	  {"change_id":"c1","entity_table":"samples","entity_id":"e1","op":"insert",
	   "payload":{"n":1},"author_id":"g1","logical_ts":"2026-07-02T10:00:00Z"}]}`
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/push", bytes.NewBufferString(body))
	req.Header.Set("Authorization", "Bearer secret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("статус %d, ожидался 200 (неизвестные поля терпимы)", resp.StatusCode)
	}
}

func TestDecompressionBombRejected(t *testing.T) {
	ts, _, _ := testServer(t)
	// >64 МиБ нулей сжимаются в десятки КБ — сжатый размер проходит
	// MaxBytesReader, но распакованный обязан упереться в лимит.
	var buf bytes.Buffer
	gw := gzip.NewWriter(&buf)
	zeros := make([]byte, 1<<20)
	for range 65 {
		gw.Write(zeros)
	}
	gw.Close()
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/push", &buf)
	req.Header.Set("Authorization", "Bearer secret")
	req.Header.Set("Content-Encoding", "gzip")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("статус %d, ожидался 413", resp.StatusCode)
	}
}

func TestReplaySkipsDuplicateChangeID(t *testing.T) {
	// Повтор change_id на диске (след сбойного ретрая до отката) —
	// реплей идемпотентен: первая копия остаётся, повтор пропускается.
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	lines := `{"seq":1,"device_id":"d","received_at":"t","change_id":"c1","entity_table":"samples","entity_id":"e1","op":"insert","payload":{},"author_id":"g","logical_ts":"t"}
{"seq":2,"device_id":"d","received_at":"t","change_id":"c1","entity_table":"samples","entity_id":"e1","op":"insert","payload":{},"author_id":"g","logical_ts":"t"}
{"seq":2,"device_id":"d","received_at":"t","change_id":"c2","entity_table":"samples","entity_id":"e2","op":"insert","payload":{},"author_id":"g","logical_ts":"t"}
`
	if err := os.WriteFile(path, []byte(lines), 0o600); err != nil {
		t.Fatal(err)
	}
	j, err := OpenJournal(path)
	if err != nil {
		t.Fatalf("реплей с повтором change_id должен пройти: %v", err)
	}
	defer j.Close()
	if j.LastSeq() != 2 {
		t.Fatalf("last_seq=%d, ожидалось 2", j.LastSeq())
	}
	out, _ := j.List(0, 100, "other")
	if len(out) != 2 || out[0].ChangeID != "c1" || out[1].ChangeID != "c2" {
		t.Fatalf("реплей дал %+v", out)
	}
}

func TestMalformedJSON(t *testing.T) {
	ts, _, _ := testServer(t)
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/push", bytes.NewBufferString("{нет"))
	req.Header.Set("Authorization", "Bearer secret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("статус %d, ожидался 400", resp.StatusCode)
	}
}
