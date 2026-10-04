import 'dart:convert';

import '../data/database.dart';

/// A stream the player can try, best first.
class PlayableStream {
  const PlayableStream(this.id, this.url, this.headers, {this.quality, required this.status, this.playFailedAt});

  final int id;
  final String url;
  final Map<String, String> headers;
  final String? quality;

  /// From the last check: unchecked, working or dead.
  final String status;
  final DateTime? playFailedAt;
}

/// A channel as the app shows it.
class ChannelEntry {
  ChannelEntry({
    required this.id,
    required this.number,
    required this.name,
    required this.categories,
    required this.logoPath,
    required this.favourite,
    required this.streams,
  });

  final String id;
  final int number;
  final String name;
  final List<String> categories;
  final String? logoPath;
  bool favourite;

  /// Best first: working and not failed in the player lately, then
  /// unchecked, then the rest.
  final List<PlayableStream> streams;

  /// Has a stream the last check found working.
  bool get working => streams.any((s) => s.status == 'working');
}

/// The app's view of iptv.db: channels, the guide, and the app-owned state
/// (favourites, hidden channels, playback failures, the last channel).
class Repository {
  Repository(this.database);

  final IptvDatabase database;

  /// How long a stream that failed in the player goes to the back of its
  /// channel's list.
  static const playFailurePenalty = Duration(days: 7);

  /// Visible channels in number order. With [onlyWorking], channels with no
  /// working stream are left out (unless nothing has been checked yet).
  List<ChannelEntry> channels({bool onlyWorking = true}) {
    final db = database.db;
    final streams = <String, List<PlayableStream>>{};
    for (final row in db.select(
      'SELECT id, channel_id, url, user_agent, referrer, quality, status, play_failed_at FROM streams ORDER BY rank',
    )) {
      final failedAt = row['play_failed_at'] as int?;
      (streams[row['channel_id'] as String] ??= []).add(
        PlayableStream(
          row['id'] as int,
          row['url'] as String,
          {
            if (row['user_agent'] != null) 'User-Agent': row['user_agent'] as String,
            if (row['referrer'] != null) 'Referer': row['referrer'] as String,
          },
          quality: row['quality'] as String?,
          status: row['status'] as String,
          playFailedAt: failedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(failedAt * 1000),
        ),
      );
    }
    final now = DateTime.now();
    final channels = <ChannelEntry>[];
    for (final row in db.select('''
      SELECT c.id, c.name, c.categories, c.logo_path, n.number, COALESCE(u.favourite, 0) AS favourite
      FROM channels c
      JOIN numbers n ON n.channel_id = c.id
      LEFT JOIN user_channels u ON u.channel_id = c.id
      WHERE COALESCE(u.hidden, 0) = 0
      ORDER BY n.number
    ''')) {
      final id = row['id'] as String;
      channels.add(
        ChannelEntry(
          id: id,
          number: row['number'] as int,
          name: row['name'] as String,
          categories: (jsonDecode(row['categories'] as String) as List).cast<String>(),
          logoPath: row['logo_path'] as String?,
          favourite: row['favourite'] == 1,
          streams: orderForPlay(streams[id] ?? const [], now),
        ),
      );
    }
    final anyChecked = channels.any((c) => c.streams.any((s) => s.status != 'unchecked'));
    if (onlyWorking && anyChecked) channels.removeWhere((c) => !c.working);
    return channels;
  }

  /// Orders a channel's streams (already in rank order) for the player.
  static List<PlayableStream> orderForPlay(List<PlayableStream> streams, DateTime now) {
    int group(PlayableStream s) {
      final failedLately = s.playFailedAt != null && now.difference(s.playFailedAt!) < playFailurePenalty;
      if (failedLately) return 3;
      return switch (s.status) {
        'working' => 0,
        'unchecked' => 1,
        _ => 2,
      };
    }

    return [...streams]..sort((a, b) => group(a).compareTo(group(b)));
  }

  /// Programmes overlapping [from]..[until], per channel, in time order.
  Map<String, List<Programme>> programmes(DateTime from, DateTime until) {
    final out = <String, List<Programme>>{};
    for (final row in database.db.select(
      'SELECT channel_id, start, stop, title, subtitle, description, category FROM programmes '
      'WHERE stop > ? AND start < ? ORDER BY start',
      [from.millisecondsSinceEpoch ~/ 1000, until.millisecondsSinceEpoch ~/ 1000],
    )) {
      final id = row['channel_id'] as String;
      (out[id] ??= []).add(
        Programme(
          channelId: id,
          start: DateTime.fromMillisecondsSinceEpoch((row['start'] as int) * 1000),
          stop: DateTime.fromMillisecondsSinceEpoch((row['stop'] as int) * 1000),
          title: row['title'] as String,
          subtitle: row['subtitle'] as String?,
          description: row['description'] as String?,
          category: row['category'] as String?,
        ),
      );
    }
    return out;
  }

  void setFavourite(String channelId, bool favourite) => database.db.execute(
    'INSERT INTO user_channels (channel_id, favourite) VALUES (?, ?) '
    'ON CONFLICT (channel_id) DO UPDATE SET favourite = excluded.favourite',
    [channelId, favourite ? 1 : 0],
  );

  void setHidden(String channelId, bool hidden) => database.db.execute(
    'INSERT INTO user_channels (channel_id, hidden) VALUES (?, ?) '
    'ON CONFLICT (channel_id) DO UPDATE SET hidden = excluded.hidden',
    [channelId, hidden ? 1 : 0],
  );

  /// mpv couldn't play [streamId]: it goes to the back of its channel's list
  /// for [playFailurePenalty].
  void recordPlayFailure(int streamId, String reason) => database.db.execute(
    'UPDATE streams SET play_failed_at = ?, play_failure = ? WHERE id = ?',
    [DateTime.now().millisecondsSinceEpoch ~/ 1000, reason, streamId],
  );

  void recordPlaySuccess(int streamId) =>
      database.db.execute('UPDATE streams SET play_failed_at = NULL, play_failure = NULL WHERE id = ?', [streamId]);

  String? get lastChannel => database.meta('app_last_channel');
  set lastChannel(String? id) => database.setMeta('app_last_channel', id);
}
