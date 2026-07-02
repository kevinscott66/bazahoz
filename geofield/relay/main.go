// GeoField relay — публичная точка приёма дельта-синхронизации (ТЗ §1.4,
// sync-protocol.md §2): один бинарь, мало памяти. Принимает пакеты мутаций
// от полевых устройств, дедуплицирует, отдаёт чужие мутации по курсору.
// Проталкивание в Postgres камералки — следующий шаг (см. README).
package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	addr := flag.String("addr", ":8080", "адрес прослушивания")
	data := flag.String("data", "relay-journal.jsonl", "путь к файлу журнала")
	flag.Parse()

	token := os.Getenv("RELAY_TOKEN")
	if token == "" {
		// Без токена не стартуем: молчаливо-открытый relay в интернете —
		// утечка данных по недрам (мастер-план §7).
		log.Fatal("RELAY_TOKEN не задан — отказ запуска (задайте секрет окружением)")
	}

	journal, err := OpenJournal(*data)
	if err != nil {
		log.Fatalf("журнал: %v", err)
	}
	defer journal.Close()

	srv := &http.Server{
		Addr:              *addr,
		Handler:           newMux(&server{journal: journal, token: token}),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       5 * time.Minute, // спутниковый канал медленный
		WriteTimeout:      5 * time.Minute,
	}
	log.Printf("relay слушает %s, журнал %s, last_seq=%d", *addr, *data, journal.LastSeq())
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
