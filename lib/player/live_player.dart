import 'package:flutter/widgets.dart';

/// Where a [LivePlayer] is in tuning a stream.
enum PlayerPhase { idle, opening, playing, failed }

class PlayerStatus {
  const PlayerStatus(this.phase, [this.error]);

  final PlayerPhase phase;
  final String? error;

  @override
  String toString() => error == null ? phase.name : '${phase.name}: $error';
}

/// A live stream player. The app talks only to this, so the backend can be
/// swapped (M0 compared the native mpv plane with media_kit's texture; see
/// docs/m0.md).
abstract class LivePlayer {
  /// Short name for logs and the M0 results.
  String get name;

  Future<void> init();

  /// Tunes [url]. [headers] carries the User-Agent and Referer some
  /// iptv-org streams need.
  Future<void> open(String url, {Map<String, String> headers = const {}});

  Future<void> stop();

  /// Sets an mpv option, e.g. alang.
  Future<void> setOption(String name, String value);

  /// Changes as a stream opens, shows its first frame, or fails.
  Stream<PlayerStatus> get status;

  /// An mpv property as a string, for diagnostics (hwdec-current,
  /// frame-drop-count, ...). Null when unavailable.
  Future<String?> property(String name);

  /// Where the picture goes. Fills its parent.
  Widget view();

  Future<void> dispose();
}

/// mpv options for live streams: hardware decoding, and a stream that stops
/// answering fails quickly instead of hanging.
const Map<String, String> liveMpvOptions = {
  'hwdec': 'auto-safe',
  'network-timeout': '10',
  'demuxer-lavf-o': 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',
  'cache': 'yes',
  'demuxer-readahead-secs': '10',
};

/// mpv's http-header-fields value for [headers].
String httpHeaderFields(Map<String, String> headers) =>
    headers.entries.map((e) => '${e.key}: ${e.value.replaceAll(',', r'\,')}').join(',');
