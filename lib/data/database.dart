import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'selection.dart';

/// A programme in the guide.
class Programme {
  const Programme({
    required this.channelId,
    required this.start,
    required this.stop,
    required this.title,
    this.subtitle,
    this.description,
    this.category,
  });

  final String channelId;
  final DateTime start;
  final DateTime stop;
  final String title;
  final String? subtitle;
  final String? description;
  final String? category;
}

/// Result of checking one stream.
class StreamHealth {
  const StreamHealth.ok(this.milliseconds) : working = true, reason = null;
  const StreamHealth.dead(this.reason, [this.milliseconds]) : working = false;

  final bool working;
  final int? milliseconds;
  final String? reason;
}

/// A stream row, as the checker and the player need it.
class StreamRow {
  const StreamRow(this.id, this.channelId, this.url, this.headers);

  final int id;
  final String channelId;
  final String url;
  final Map<String, String> headers;
}

/// ~/.local/share/couchbox-iptv/iptv.db. The refresh job writes channels,
/// streams, programmes and logos; the app reads them and owns favourites,
/// hidden channels and playback failures. WAL, so the app reads while the job
/// writes.
class IptvDatabase {
  IptvDatabase._(this.db);

  final Database db;

  static const schemaVersion = 1;

  factory IptvDatabase.open(String path) {
    File(path).parent.createSync(recursive: true);
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA busy_timeout = 5000');
    final database = IptvDatabase._(db);
    database._migrate();
    return database;
  }

  factory IptvDatabase.memory() {
    final database = IptvDatabase._(sqlite3.openInMemory());
    database._migrate();
    return database;
  }

  void close() => db.close();

  void _migrate() {
    // Per connection: without it, removing a channel would leave its streams.
    db.execute('PRAGMA foreign_keys = ON');
    final version = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version >= schemaVersion) return;
    db.execute('''
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE IF NOT EXISTS channels (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        country TEXT,
        categories TEXT NOT NULL,   -- JSON list of iptv-org category ids
        languages TEXT NOT NULL,    -- JSON list of ISO 639-3 codes
        logo_url TEXT,
        logo_path TEXT,             -- cached file, once downloaded
        guide_source TEXT,          -- "pluto" or null
        guide_id TEXT
      );
      CREATE TABLE IF NOT EXISTS streams (
        id INTEGER PRIMARY KEY,
        channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
        url TEXT NOT NULL,
        title TEXT,
        quality TEXT,
        labels TEXT NOT NULL,       -- JSON list: "Geo-blocked", "Not 24/7"
        user_agent TEXT,
        referrer TEXT,
        rank INTEGER NOT NULL,      -- 0 is the channel's best stream
        status TEXT NOT NULL DEFAULT 'unchecked',  -- unchecked, working, dead
        checked_at INTEGER,         -- unix seconds
        response_ms INTEGER,
        reason TEXT,
        UNIQUE (channel_id, url)
      );
      CREATE TABLE IF NOT EXISTS programmes (
        channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
        start INTEGER NOT NULL,     -- unix seconds
        stop INTEGER NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT,
        description TEXT,
        category TEXT,
        PRIMARY KEY (channel_id, start)
      );
      -- Channel numbers outlive the channels table, so a channel that drops
      -- out and comes back keeps its number.
      CREATE TABLE IF NOT EXISTS numbers (
        channel_id TEXT PRIMARY KEY,
        number INTEGER NOT NULL UNIQUE
      );
      -- Owned by the app.
      CREATE TABLE IF NOT EXISTS user_channels (
        channel_id TEXT PRIMARY KEY,
        favourite INTEGER NOT NULL DEFAULT 0,
        hidden INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS streams_channel ON streams (channel_id, rank);
      CREATE INDEX IF NOT EXISTS programmes_time ON programmes (start, stop);
    ''');
    db.execute('PRAGMA user_version = $schemaVersion');
  }

  void _transaction(void Function() body) {
    db.execute('BEGIN IMMEDIATE');
    try {
      body();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  String? meta(String key) => db.select('SELECT value FROM meta WHERE key = ?', [key]).firstOrNull?['value'] as String?;

  void setMeta(String key, String? value) => db.execute(
    'INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value',
    [key, value],
  );

  /// Replaces the channel list with [channels]. A stream that stays keeps its
  /// last check; channels that left take their streams and programmes with
  /// them. New channels get the next free numbers, in [channels]' order.
  void replaceChannels(List<SelectedChannel> channels) {
    _transaction(() {
      final keep = {for (final c in channels) c.channel.id};
      final existing = [for (final row in db.select('SELECT id FROM channels')) row['id'] as String];
      final remove = db.prepare('DELETE FROM channels WHERE id = ?');
      for (final id in existing.where((id) => !keep.contains(id))) {
        remove.execute([id]);
      }
      remove.close();

      final upsertChannel = db.prepare('''
        INSERT INTO channels (id, name, country, categories, languages, logo_url, guide_source, guide_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET
          name = excluded.name, country = excluded.country, categories = excluded.categories,
          languages = excluded.languages, guide_source = excluded.guide_source, guide_id = excluded.guide_id,
          logo_path = CASE WHEN logo_url IS excluded.logo_url THEN logo_path END,
          logo_url = excluded.logo_url
      ''');
      final upsertStream = db.prepare('''
        INSERT INTO streams (channel_id, url, title, quality, labels, user_agent, referrer, rank)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (channel_id, url) DO UPDATE SET
          title = excluded.title, quality = excluded.quality, labels = excluded.labels,
          user_agent = excluded.user_agent, referrer = excluded.referrer, rank = excluded.rank
      ''');
      final dropStreams = db.prepare(
        'DELETE FROM streams WHERE channel_id = ? AND url NOT IN (SELECT value FROM json_each(?))',
      );
      var next = (db.select('SELECT MAX(number) AS n FROM numbers').first['n'] as int?) ?? 0;
      final numbered = {for (final row in db.select('SELECT channel_id FROM numbers')) row['channel_id'] as String};
      final addNumber = db.prepare('INSERT INTO numbers (channel_id, number) VALUES (?, ?)');

      for (final c in channels) {
        final plutoId = c.plutoId;
        upsertChannel.execute([
          c.channel.id,
          c.channel.name,
          c.channel.country,
          jsonEncode(c.channel.categories),
          jsonEncode(c.languages),
          c.logo?.url,
          plutoId == null ? null : 'pluto',
          plutoId,
        ]);
        for (final (rank, s) in c.streams.indexed) {
          upsertStream.execute([
            c.channel.id,
            s.url,
            s.title,
            s.quality,
            jsonEncode(s.labels),
            s.userAgent,
            s.referrer,
            rank,
          ]);
        }
        dropStreams.execute([
          c.channel.id,
          jsonEncode([for (final s in c.streams) s.url]),
        ]);
        if (!numbered.contains(c.channel.id)) addNumber.execute([c.channel.id, ++next]);
      }
      for (final statement in [upsertChannel, upsertStream, dropStreams, addNumber]) {
        statement.close();
      }
    });
  }

  /// Streams not checked since [since] (all of them when null), never-checked
  /// first, then oldest check first. Each result is saved as it comes in, so
  /// a stopped run picks up where it left off.
  List<StreamRow> streamsToCheck({DateTime? since}) => [
    for (final row in db.select(
      'SELECT id, channel_id, url, user_agent, referrer FROM streams '
      'WHERE checked_at IS NULL OR checked_at < ? '
      'ORDER BY checked_at IS NOT NULL, checked_at, rank',
      [since == null ? 1 << 62 : since.millisecondsSinceEpoch ~/ 1000],
    ))
      StreamRow(row['id'] as int, row['channel_id'] as String, row['url'] as String, {
        if (row['user_agent'] != null) 'User-Agent': row['user_agent'] as String,
        if (row['referrer'] != null) 'Referer': row['referrer'] as String,
      }),
  ];

  void recordHealth(int streamId, StreamHealth health, DateTime at) =>
      db.execute('UPDATE streams SET status = ?, checked_at = ?, response_ms = ?, reason = ? WHERE id = ?', [
        health.working ? 'working' : 'dead',
        at.millisecondsSinceEpoch ~/ 1000,
        health.milliseconds,
        health.reason,
        streamId,
      ]);

  /// Channels whose guide comes from [source], as guide id to channel ids.
  Map<String, List<String>> guideIds(String source) {
    final ids = <String, List<String>>{};
    for (final row in db.select('SELECT id, guide_id FROM channels WHERE guide_source = ?', [source])) {
      (ids[row['guide_id'] as String] ??= []).add(row['id'] as String);
    }
    return ids;
  }

  /// Replaces the programmes of [channelIds] with [programmes].
  void replaceProgrammes(Iterable<String> channelIds, List<Programme> programmes) {
    _transaction(() {
      final clear = db.prepare('DELETE FROM programmes WHERE channel_id = ?');
      for (final id in channelIds) {
        clear.execute([id]);
      }
      clear.close();
      final insert = db.prepare(
        'INSERT OR REPLACE INTO programmes (channel_id, start, stop, title, subtitle, description, category) VALUES (?, ?, ?, ?, ?, ?, ?)',
      );
      for (final p in programmes) {
        insert.execute([
          p.channelId,
          p.start.millisecondsSinceEpoch ~/ 1000,
          p.stop.millisecondsSinceEpoch ~/ 1000,
          p.title,
          p.subtitle,
          p.description,
          p.category,
        ]);
      }
      insert.close();
    });
  }

  /// Programmes that ended before [before] are of no use to a live guide.
  void dropOldProgrammes(DateTime before) =>
      db.execute('DELETE FROM programmes WHERE stop < ?', [before.millisecondsSinceEpoch ~/ 1000]);

  /// Logos not downloaded yet, as channel id to URL.
  Map<String, String> logosToFetch() => {
    for (final row in db.select('SELECT id, logo_url FROM channels WHERE logo_url IS NOT NULL AND logo_path IS NULL'))
      row['id'] as String: row['logo_url'] as String,
  };

  void setLogoPath(String channelId, String path) =>
      db.execute('UPDATE channels SET logo_path = ? WHERE id = ?', [path, channelId]);

  /// Counts for the run summary: channels, streams by status, programmes.
  Map<String, int> counts() {
    final out = <String, int>{
      'channels': db.select('SELECT COUNT(*) AS n FROM channels').first['n'] as int,
      'programmes': db.select('SELECT COUNT(*) AS n FROM programmes').first['n'] as int,
    };
    for (final row in db.select('SELECT status, COUNT(*) AS n FROM streams GROUP BY status')) {
      out['streams_${row['status']}'] = row['n'] as int;
    }
    return out;
  }
}
