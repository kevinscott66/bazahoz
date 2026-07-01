import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Открытие локальной базы. Подмножество миграции
/// geofield/core/schema/001_initial.sql, нужное прототипу (projects, samples,
/// change_log). Полная схема — в core/schema; здесь только то, что трогает
/// экран сбора пробы, один в один по колонкам.
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

    await d.execute('CREATE INDEX idx_samples_number ON samples(sample_number)');
    await d.execute('CREATE INDEX idx_samples_barcode ON samples(barcode)');
    await d.execute(
        'CREATE INDEX idx_samples_parent ON samples(parent_type, parent_id)');
    await d.execute(
        'CREATE INDEX idx_changelog_unsynced ON change_log(synced) WHERE synced = 0');
  }
}
