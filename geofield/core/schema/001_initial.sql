-- GeoField — начальная схема локальной базы (SQLite)
-- Версия схемы: 1
-- Применяется миграционным раннером (см. README.md). Раннер выставляет
-- PRAGMA user_version = 1 после успешного применения этого файла.
--
-- Принципы:
--   * id везде — UUID, генерируется на устройстве (офлайн, без коллизий).
--   * Каждая пользовательская запись несёт служебные поля синхронизации:
--       author_id, created_at, modified_at, version, sync_status, deleted.
--   * Времена — строки ISO-8601 в UTC ('2026-07-01T09:12:00Z').
--   * Координаты точек/скважин хранятся канонически в WGS-84 (lat/lon),
--     отображение в СК-42/Гаусса-Крюгера/МСК — пересчётом на лету.
--   * Удаление — мягкое (deleted = 1), чтобы синхронизация могла его донести.
--   * Схема готова к синхронизации с этапа 1, хотя MVP — один пользователь.

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- Пользователи и роли
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    id           TEXT    PRIMARY KEY NOT NULL,
    full_name    TEXT    NOT NULL,
    role         TEXT    NOT NULL,            -- geologist | documentarian | qc | office
    created_at   TEXT    NOT NULL,
    modified_at  TEXT    NOT NULL,
    version      INTEGER NOT NULL DEFAULT 1,
    sync_status  TEXT    NOT NULL DEFAULT 'pending',  -- pending|queued|sent|confirmed
    deleted      INTEGER NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------------
-- Проект → партия → маршрут
-- ---------------------------------------------------------------------------
CREATE TABLE projects (
    id                    TEXT    PRIMARY KEY NOT NULL,
    name                  TEXT    NOT NULL,
    area                  TEXT,                -- участок
    default_crs           TEXT,                -- рабочая система координат, напр. 'SK-42/GK-7'
    sample_numbering      TEXT,                -- шаблон номера, напр. 'SUZ-{seq:05}'
    dictionaries_version  TEXT,                -- версия справочников проекта
    author_id             TEXT    REFERENCES users(id),
    created_at            TEXT    NOT NULL,
    modified_at           TEXT    NOT NULL,
    version               INTEGER NOT NULL DEFAULT 1,
    sync_status           TEXT    NOT NULL DEFAULT 'pending',
    deleted               INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE parties (
    id           TEXT    PRIMARY KEY NOT NULL,
    project_id   TEXT    NOT NULL REFERENCES projects(id),
    name         TEXT    NOT NULL,             -- партия/отряд
    author_id    TEXT    REFERENCES users(id),
    created_at   TEXT    NOT NULL,
    modified_at  TEXT    NOT NULL,
    version      INTEGER NOT NULL DEFAULT 1,
    sync_status  TEXT    NOT NULL DEFAULT 'pending',
    deleted      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE routes (
    id            TEXT    PRIMARY KEY NOT NULL,
    party_id      TEXT    NOT NULL REFERENCES parties(id),
    geologist_id  TEXT    REFERENCES users(id),
    route_date    TEXT    NOT NULL,            -- дата маршрута (день работы)
    title         TEXT,
    author_id     TEXT    REFERENCES users(id),
    created_at    TEXT    NOT NULL,
    modified_at   TEXT    NOT NULL,
    version       INTEGER NOT NULL DEFAULT 1,
    sync_status   TEXT    NOT NULL DEFAULT 'pending',
    deleted       INTEGER NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------------
-- Точки наблюдения
-- ---------------------------------------------------------------------------
CREATE TABLE observation_points (
    id              TEXT    PRIMARY KEY NOT NULL,
    route_id        TEXT    NOT NULL REFERENCES routes(id),
    number          TEXT    NOT NULL,          -- номер точки (автонумерация, переопределяемо)
    lat             REAL,                      -- WGS-84
    lon             REAL,
    elevation       REAL,
    coord_source    TEXT,                      -- gps | manual
    gps_accuracy_m  REAL,                      -- точность приёмника, м
    observed_at     TEXT,
    object_type     TEXT,                      -- код из dictionaries(dict_type='object_type')
    rock_code       TEXT,                      -- код из dictionaries(dict_type='rock')
    color_code      TEXT,
    grain           TEXT,
    alteration_code TEXT,
    minerals        TEXT,                      -- JSON: [{code, intensity}]
    note            TEXT,
    is_draft        INTEGER NOT NULL DEFAULT 1,-- черновик, пока не заполнены обязательные поля
    author_id       TEXT    REFERENCES users(id),
    created_at      TEXT    NOT NULL,
    modified_at     TEXT    NOT NULL,
    version         INTEGER NOT NULL DEFAULT 1,
    sync_status     TEXT    NOT NULL DEFAULT 'pending',
    deleted         INTEGER NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------------
-- Скважины, интервалы керна, инклинометрия
-- ---------------------------------------------------------------------------
CREATE TABLE boreholes (
    id              TEXT    PRIMARY KEY NOT NULL,
    project_id      TEXT    NOT NULL REFERENCES projects(id),
    route_id        TEXT    REFERENCES routes(id),
    name            TEXT    NOT NULL,
    collar_lat      REAL,                      -- устье, WGS-84
    collar_lon      REAL,
    collar_elev     REAL,
    azimuth         REAL,                      -- азимут ствола
    dip             REAL,                      -- угол наклона ствола
    total_depth     REAL,                      -- забой, м
    author_id       TEXT    REFERENCES users(id),
    created_at      TEXT    NOT NULL,
    modified_at     TEXT    NOT NULL,
    version         INTEGER NOT NULL DEFAULT 1,
    sync_status     TEXT    NOT NULL DEFAULT 'pending',
    deleted         INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE core_intervals (
    id                TEXT    PRIMARY KEY NOT NULL,
    borehole_id       TEXT    NOT NULL REFERENCES boreholes(id),
    depth_from        REAL    NOT NULL,        -- от, м
    depth_to          REAL    NOT NULL,        -- до, м
    lithology_code    TEXT,                    -- код из dictionaries(dict_type='lithology')
    core_recovery_pct REAL,                    -- выход керна, %
    measured_length   REAL,                    -- замеренная длина, м
    note              TEXT,
    author_id         TEXT    REFERENCES users(id),
    created_at        TEXT    NOT NULL,
    modified_at       TEXT    NOT NULL,
    version           INTEGER NOT NULL DEFAULT 1,
    sync_status       TEXT    NOT NULL DEFAULT 'pending',
    deleted           INTEGER NOT NULL DEFAULT 0,
    CHECK (depth_to >= depth_from),
    CHECK (core_recovery_pct IS NULL OR (core_recovery_pct >= 0 AND core_recovery_pct <= 100))
);

CREATE TABLE inclinometry (
    id           TEXT    PRIMARY KEY NOT NULL,
    borehole_id  TEXT    NOT NULL REFERENCES boreholes(id),
    depth        REAL    NOT NULL,
    azimuth      REAL,
    dip          REAL,
    author_id    TEXT    REFERENCES users(id),
    created_at   TEXT    NOT NULL,
    modified_at  TEXT    NOT NULL,
    version      INTEGER NOT NULL DEFAULT 1,
    sync_status  TEXT    NOT NULL DEFAULT 'pending',
    deleted      INTEGER NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------------
-- Структурные замеры (полиморфный родитель: точка или интервал)
-- ---------------------------------------------------------------------------
CREATE TABLE structural_measurements (
    id            TEXT    PRIMARY KEY NOT NULL,
    parent_type   TEXT    NOT NULL,            -- point | interval
    parent_id     TEXT    NOT NULL,
    measure_type  TEXT,                        -- bedding | foliation | joint | vein ...
    dip_azimuth   REAL,                        -- азимут падения
    dip_angle     REAL,                        -- угол падения
    source        TEXT,                        -- manual | sensor
    is_true_angle INTEGER NOT NULL DEFAULT 0,  -- истинный угол по ориентированному керну
    note          TEXT,
    author_id     TEXT    REFERENCES users(id),
    created_at    TEXT    NOT NULL,
    modified_at   TEXT    NOT NULL,
    version       INTEGER NOT NULL DEFAULT 1,
    sync_status   TEXT    NOT NULL DEFAULT 'pending',
    deleted       INTEGER NOT NULL DEFAULT 0,
    CHECK (parent_type IN ('point', 'interval')),
    CHECK (dip_azimuth IS NULL OR (dip_azimuth >= 0 AND dip_azimuth < 360)),
    CHECK (dip_angle IS NULL OR (dip_angle >= 0 AND dip_angle <= 90))
);

-- ---------------------------------------------------------------------------
-- Пробы (сквозная сущность) и результаты анализов
-- ---------------------------------------------------------------------------
CREATE TABLE samples (
    id            TEXT    PRIMARY KEY NOT NULL,
    project_id    TEXT    NOT NULL REFERENCES projects(id),
    parent_type   TEXT,                        -- point | interval (может быть NULL для свободной пробы)
    parent_id     TEXT,
    sample_number TEXT    NOT NULL,            -- по схеме проекта (sample_numbering)
    sample_type   TEXT    NOT NULL,            -- core|sludge|schlich|soil|channel|grab
    barcode       TEXT,                        -- штрихкод/QR (печать на бирку)
    depth_from    REAL,                        -- интервал отбора (для керна)
    depth_to      REAL,
    mass          REAL,
    length_m      REAL,
    status        TEXT    NOT NULL DEFAULT 'collected', -- collected|packed|sent|result_received
    note          TEXT,
    author_id     TEXT    REFERENCES users(id),
    created_at    TEXT    NOT NULL,
    modified_at   TEXT    NOT NULL,
    version       INTEGER NOT NULL DEFAULT 1,
    sync_status   TEXT    NOT NULL DEFAULT 'pending',
    deleted       INTEGER NOT NULL DEFAULT 0,
    CHECK (parent_type IS NULL OR parent_type IN ('point', 'interval')),
    CHECK (status IN ('collected', 'packed', 'sent', 'result_received')),
    CHECK (depth_to IS NULL OR depth_from IS NULL OR depth_to >= depth_from)
);

CREATE TABLE sample_results (
    id           TEXT    PRIMARY KEY NOT NULL,
    sample_id    TEXT    NOT NULL REFERENCES samples(id),
    lab_code     TEXT,                         -- код из dictionaries(dict_type='lab')
    element      TEXT    NOT NULL,             -- Au | Ag | Cu ...
    value        REAL,
    unit         TEXT,                         -- g/t | % | ppm
    method       TEXT,
    analyzed_at  TEXT,
    author_id    TEXT    REFERENCES users(id),
    created_at   TEXT    NOT NULL,
    modified_at  TEXT    NOT NULL,
    version      INTEGER NOT NULL DEFAULT 1,
    sync_status  TEXT    NOT NULL DEFAULT 'pending',
    deleted      INTEGER NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------------
-- Фотографии (полиморфный родитель; отдельная очередь отправки)
-- ---------------------------------------------------------------------------
CREATE TABLE photos (
    id                 TEXT    PRIMARY KEY NOT NULL,
    parent_type        TEXT    NOT NULL,       -- point | interval | sample | borehole
    parent_id          TEXT    NOT NULL,
    file_path          TEXT    NOT NULL,       -- локальный путь к оригиналу
    thumbnail_path     TEXT,
    lat                REAL,
    lon                REAL,
    taken_at           TEXT,
    defer_until_office INTEGER NOT NULL DEFAULT 1, -- не отправлять до камералки
    upload_status      TEXT    NOT NULL DEFAULT 'pending', -- pending|queued|uploaded
    author_id          TEXT    REFERENCES users(id),
    created_at         TEXT    NOT NULL,
    modified_at        TEXT    NOT NULL,
    version            INTEGER NOT NULL DEFAULT 1,
    sync_status        TEXT    NOT NULL DEFAULT 'pending',
    deleted            INTEGER NOT NULL DEFAULT 0,
    CHECK (parent_type IN ('point', 'interval', 'sample', 'borehole'))
);

-- ---------------------------------------------------------------------------
-- Справочники (управляемые, версионируемые, обновляются с сервера)
-- ---------------------------------------------------------------------------
CREATE TABLE dictionaries (
    id                TEXT    PRIMARY KEY NOT NULL,
    project_id        TEXT    REFERENCES projects(id), -- NULL = глобальный справочник
    dict_type         TEXT    NOT NULL,        -- rock|color|mineral|alteration|sample_type|
                                               -- lab|unit|object_type|lithology
    code              TEXT    NOT NULL,
    label             TEXT    NOT NULL,
    color             TEXT,                    -- семантический цвет (напр. типы проб)
    sort_order        INTEGER,
    meta              TEXT,                    -- JSON доп. полей
    is_pending_review INTEGER NOT NULL DEFAULT 0, -- добавлено в поле «на проверку»
    dict_version      TEXT,
    author_id         TEXT    REFERENCES users(id),
    created_at        TEXT    NOT NULL,
    modified_at       TEXT    NOT NULL,
    version           INTEGER NOT NULL DEFAULT 1,
    sync_status       TEXT    NOT NULL DEFAULT 'pending',
    deleted           INTEGER NOT NULL DEFAULT 0,
    UNIQUE (project_id, dict_type, code)
);

-- ---------------------------------------------------------------------------
-- Синхронизация: журнал изменений (event sourcing), состояние, конфликты, история
-- ---------------------------------------------------------------------------

-- Append-only лог мутаций. Основа дельта-синхронизации (см. sync-protocol.md).
CREATE TABLE change_log (
    seq           INTEGER PRIMARY KEY AUTOINCREMENT,  -- локальный порядковый номер
    change_id     TEXT    NOT NULL UNIQUE,            -- UUID мутации (идемпотентность)
    entity_table  TEXT    NOT NULL,
    entity_id     TEXT    NOT NULL,
    op            TEXT    NOT NULL,                   -- insert | update | delete
    payload       TEXT    NOT NULL,                   -- JSON: изменённые поля (для update — дельта)
    author_id     TEXT,
    device_id     TEXT,
    logical_ts    TEXT    NOT NULL,                   -- гибридные логич. часы (HLC)
    synced        INTEGER NOT NULL DEFAULT 0,         -- подтверждено relay-узлом
    ack_batch     TEXT,                               -- id пакета подтверждения
    CHECK (op IN ('insert', 'update', 'delete'))
);

-- Пары ключ-значение состояния синхронизации:
--   device_id, last_pulled_seq (курсор входящих с сервера), hlc_state
--   (состояние гибридных логических часов, §4), last_session, ...
CREATE TABLE sync_state (
    key    TEXT PRIMARY KEY NOT NULL,
    value  TEXT
);

-- HLC последнего писателя каждой строки — для LWW при применении чужих
-- мутаций (sync-protocol.md §4-5). Локальная вспомогательная таблица
-- устройства: НЕ синхронизируется, ведётся в той же транзакции, что и
-- мутация/применение.
CREATE TABLE row_clocks (
    entity_table TEXT NOT NULL,
    entity_id    TEXT NOT NULL,
    hlc_ts       TEXT NOT NULL,          -- сортируемая строка HLC
    PRIMARY KEY (entity_table, entity_id)
);

-- Конфликты правок одной записи двумя авторами — для ручного разбора в камералке.
CREATE TABLE conflicts (
    id             TEXT    PRIMARY KEY NOT NULL,
    entity_table   TEXT    NOT NULL,
    entity_id      TEXT    NOT NULL,
    field          TEXT,
    local_value    TEXT,
    remote_value   TEXT,
    local_version  INTEGER,
    remote_version INTEGER,
    detected_at    TEXT    NOT NULL,
    resolved       INTEGER NOT NULL DEFAULT 0,
    resolution     TEXT                                -- 'local' | 'remote' | конкретное значение
);

-- История версий: старая версия никогда не стирается, а архивируется.
CREATE TABLE record_history (
    id            TEXT    PRIMARY KEY NOT NULL,
    entity_table  TEXT    NOT NULL,
    entity_id     TEXT    NOT NULL,
    version       INTEGER NOT NULL,
    snapshot      TEXT    NOT NULL,                    -- JSON полной записи на момент версии
    author_id     TEXT,
    archived_at   TEXT    NOT NULL
);

-- ---------------------------------------------------------------------------
-- Индексы (раздел 10.4 ТЗ: искать по номеру пробы, штрихкоду, скважине, маршруту)
-- ---------------------------------------------------------------------------
CREATE INDEX idx_points_route      ON observation_points(route_id);
CREATE INDEX idx_boreholes_project ON boreholes(project_id);
CREATE INDEX idx_intervals_bh      ON core_intervals(borehole_id, depth_from);
CREATE INDEX idx_struct_parent     ON structural_measurements(parent_type, parent_id);
CREATE INDEX idx_samples_number    ON samples(sample_number);
CREATE INDEX idx_samples_barcode   ON samples(barcode);
CREATE INDEX idx_samples_parent    ON samples(parent_type, parent_id);
CREATE INDEX idx_results_sample    ON sample_results(sample_id);
CREATE INDEX idx_photos_parent     ON photos(parent_type, parent_id);
CREATE INDEX idx_dict_type         ON dictionaries(project_id, dict_type);
CREATE INDEX idx_changelog_unsynced ON change_log(synced) WHERE synced = 0;
