import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Открытие локальной базы. Подмножество миграции
/// geofield/core/schema/001_initial.sql, нужное прототипу (projects, routes,
/// observation_points, structural_measurements, samples, dictionaries,
/// change_log). Полная схема — в core/schema; здесь один в один по колонкам
/// то, что трогают экраны точки наблюдения и сбора пробы.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static Future<AppDatabase> open({String? path}) async {
    if (_isDesktop) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dbPath = path ??
        p.join(await databaseFactory.getDatabasesPath(), 'geofield.db');

    final database = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (d) async {
          await d.execute('PRAGMA foreign_keys = ON');
          await d.execute('PRAGMA journal_mode = WAL');
          await d.execute('PRAGMA synchronous = NORMAL');
          await d.execute('PRAGMA busy_timeout = 5000');
        },
        onCreate: (d, _) => _migrate001(d),
      ),
    );
    return AppDatabase._(database);
  }

  static Future<void> _migrate001(Database d) async {
    await d.execute('''
      CREATE TABLE projects (
        id                   TEXT PRIMARY KEY NOT NULL,
        name                 TEXT NOT NULL,
        area                 TEXT,
        default_crs          TEXT,
        sample_numbering     TEXT,
        dictionaries_version TEXT,
        author_id            TEXT,
        created_at           TEXT NOT NULL,
        modified_at          TEXT NOT NULL,
        version              INTEGER NOT NULL DEFAULT 1,
        sync_status          TEXT NOT NULL DEFAULT 'pending',
        deleted              INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await d.execute('''
      CREATE TABLE routes (
        id           TEXT PRIMARY KEY NOT NULL,
        party_id     TEXT,
        geologist_id TEXT,
        route_date   TEXT NOT NULL,
        title        TEXT,
        author_id    TEXT,
        created_at   TEXT NOT NULL,
        modified_at  TEXT NOT NULL,
        version      INTEGER NOT NULL DEFAULT 1,
        sync_status  TEXT NOT NULL DEFAULT 'pending',
        deleted      INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await d.execute('''
      CREATE TABLE observation_points (
        id              TEXT PRIMARY KEY NOT NULL,
        route_id        TEXT NOT NULL REFERENCES routes(id),
        number          TEXT NOT NULL,
        lat             REAL,
        lon             REAL,
        elevation       REAL,
        coord_source    TEXT,
        gps_accuracy_m  REAL,
        observed_at     TEXT,
        object_type     TEXT,
        rock_code       TEXT,
        color_code      TEXT,
        grain           TEXT,
        alteration_code TEXT,
        minerals        TEXT,
        note            TEXT,
        is_draft        INTEGER NOT NULL DEFAULT 1,
        author_id       TEXT,
        created_at      TEXT NOT NULL,
        modified_at     TEXT NOT NULL,
        version         INTEGER NOT NULL DEFAULT 1,
        sync_status     TEXT NOT NULL DEFAULT 'pending',
        deleted         INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await d.execute('''
      CREATE TABLE structural_measurements (
        id            TEXT PRIMARY KEY NOT NULL,
        parent_type   TEXT NOT NULL,
        parent_id     TEXT NOT NULL,
        measure_type  TEXT,
        dip_azimuth   REAL,
        dip_angle     REAL,
        source        TEXT,
        is_true_angle INTEGER NOT NULL DEFAULT 0,
        note          TEXT,
        author_id     TEXT,
        created_at    TEXT NOT NULL,
        modified_at   TEXT NOT NULL,
        version       INTEGER NOT NULL DEFAULT 1,
        sync_status   TEXT NOT NULL DEFAULT 'pending',
        deleted       INTEGER NOT NULL DEFAULT 0,
        CHECK (parent_type IN ('point','interval')),
        CHECK (dip_azimuth IS NULL OR (dip_azimuth >= 0 AND dip_azimuth < 360)),
        CHECK (dip_angle IS NULL OR (dip_angle >= 0 AND dip_angle <= 90))
      )
    ''');

    await d.execute('''
      CREATE TABLE dictionaries (
        id                TEXT PRIMARY KEY NOT NULL,
        project_id        TEXT REFERENCES projects(id),
        dict_type         TEXT NOT NULL,
        code              TEXT NOT NULL,
        label             TEXT NOT NULL,
        color             TEXT,
        sort_order        INTEGER,
        meta              TEXT,
        is_pending_review INTEGER NOT NULL DEFAULT 0,
        dict_version      TEXT,
        author_id         TEXT,
        created_at        TEXT NOT NULL,
        modified_at       TEXT NOT NULL,
        version           INTEGER NOT NULL DEFAULT 1,
        sync_status       TEXT NOT NULL DEFAULT 'pending',
        deleted           INTEGER NOT NULL DEFAULT 0,
        UNIQUE (project_id, dict_type, code)
      )
    ''');

    await d.execute('''
      CREATE TABLE samples (
        id            TEXT PRIMARY KEY NOT NULL,
        project_id    TEXT NOT NULL REFERENCES projects(id),
        parent_type   TEXT,
        parent_id     TEXT,
        sample_number TEXT NOT NULL,
        sample_type   TEXT NOT NULL,
        barcode       TEXT,
        depth_from    REAL,
        depth_to      REAL,
        mass          REAL,
        length_m      REAL,
        status        TEXT NOT NULL DEFAULT 'collected',
        note          TEXT,
        author_id     TEXT,
        created_at    TEXT NOT NULL,
        modified_at   TEXT NOT NULL,
        version       INTEGER NOT NULL DEFAULT 1,
        sync_status   TEXT NOT NULL DEFAULT 'pending',
        deleted       INTEGER NOT NULL DEFAULT 0,
        CHECK (parent_type IS NULL OR parent_type IN ('point','interval')),
        CHECK (status IN ('collected','packed','sent','result_received')),
        CHECK (depth_to IS NULL OR depth_from IS NULL OR depth_to >= depth_from)
      )
    ''');

    await d.execute('''
      CREATE TABLE change_log (
        seq          INTEGER PRIMARY KEY AUTOINCREMENT,
        change_id    TEXT NOT NULL UNIQUE,
        entity_table TEXT NOT NULL,
        entity_id    TEXT NOT NULL,
        op           TEXT NOT NULL,
        payload      TEXT NOT NULL,
        author_id    TEXT,
        device_id    TEXT,
        logical_ts   TEXT NOT NULL,
        synced       INTEGER NOT NULL DEFAULT 0,
        ack_batch    TEXT,
        CHECK (op IN ('insert','update','delete'))
      )
    ''');

    await d.execute('''
      CREATE TABLE sync_state (
        key    TEXT PRIMARY KEY NOT NULL,
        value  TEXT
      )
    ''');

    await d.execute('''
      CREATE TABLE conflicts (
        id             TEXT PRIMARY KEY NOT NULL,
        entity_table   TEXT NOT NULL,
        entity_id      TEXT NOT NULL,
        field          TEXT,
        local_value    TEXT,
        remote_value   TEXT,
        local_version  INTEGER,
        remote_version INTEGER,
        detected_at    TEXT NOT NULL,
        resolved       INTEGER NOT NULL DEFAULT 0,
        resolution     TEXT
      )
    ''');

    await d.execute('''
      CREATE TABLE record_history (
        id            TEXT PRIMARY KEY NOT NULL,
        entity_table  TEXT NOT NULL,
        entity_id     TEXT NOT NULL,
        version       INTEGER NOT NULL,
        snapshot      TEXT NOT NULL,
        author_id     TEXT,
        archived_at   TEXT NOT NULL
      )
    ''');

    await d.execute('CREATE INDEX idx_samples_number ON samples(sample_number)');
    await d.execute('CREATE INDEX idx_samples_barcode ON samples(barcode)');
    await d.execute(
        'CREATE INDEX idx_samples_parent ON samples(parent_type, parent_id)');
    await d.execute(
        'CREATE INDEX idx_changelog_unsynced ON change_log(synced) WHERE synced = 0');
  }
}
