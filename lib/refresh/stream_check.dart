import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/database.dart';
import 'http.dart';

/// Checks that a stream answers with something playable, as cheaply as
/// possible: for HLS the playlist, the lowest-bitrate variant and the first
/// 64 KiB of one segment; for MPEG-TS the first 64 KiB; for DASH only the
/// manifest (FFmpeg may still fail to play it; the app reports that).
class StreamChecker {
  StreamChecker(this.client, {this.timeout = const Duration(seconds: 10)});

  final HttpClient client;
  final Duration timeout;

  Future<StreamHealth> check(String url, Map<String, String> headers) async {
    final clock = Stopwatch()..start();
    try {
      final reason = await _check(Uri.parse(url), headers, depth: 0);
      return reason == null ? StreamHealth.ok(clock.elapsedMilliseconds) : StreamHealth.dead(reason);
    } on TimeoutException {
      return const StreamHealth.dead('timeout');
    } on SocketException catch (e) {
      return StreamHealth.dead('network: ${e.osError?.message ?? e.message}');
    } on HandshakeException {
      return const StreamHealth.dead('TLS handshake failed');
    } on HttpException catch (e) {
      return StreamHealth.dead('HTTP: ${e.message}');
    } on FormatException catch (e) {
      return StreamHealth.dead('bad URL: ${e.message}');
    }
  }

  /// Null when playable, otherwise why not.
  Future<String?> _check(Uri url, Map<String, String> headers, {required int depth}) async {
    if (depth > 3) return 'playlists nested too deep';
    final r = await fetchHead(client, url, headers: headers, timeout: timeout);
    if (r.status != HttpStatus.ok && r.status != HttpStatus.partialContent) return 'HTTP ${r.status}';
    final head = utf8.decode(r.body.take(4096).toList(), allowMalformed: true).trimLeft();

    if (head.startsWith('#EXTM3U')) {
      final playlist = utf8.decode(r.body, allowMalformed: true);
      final next = nextHlsUri(playlist);
      if (next == null) return 'empty HLS playlist';
      final target = r.url.resolve(next.uri);
      if (next.isPlaylist) return _check(target, headers, depth: depth + 1);
      final segment = await fetchHead(client, target, headers: headers, maxBytes: 64 * 1024, timeout: timeout);
      if (segment.status != HttpStatus.ok && segment.status != HttpStatus.partialContent) {
        return 'segment HTTP ${segment.status}';
      }
      return segment.body.length < 188 ? 'empty segment' : null;
    }
    if (head.startsWith('<') && head.contains('<MPD')) return null;
    if (head.startsWith('<')) return 'web page, not a stream';
    // Anything else binary: MPEG-TS (0x47 sync bytes) or another container.
    return r.body.length < 188 ? 'empty response' : null;
  }
}

/// The next thing to fetch in an HLS playlist: in a master playlist the
/// lowest-bandwidth variant (another playlist), in a media playlist the first
/// segment. Null when there is neither.
({String uri, bool isPlaylist})? nextHlsUri(String playlist) {
  final lines = const LineSplitter().convert(playlist).map((l) => l.trim()).toList();
  int? bestBandwidth;
  String? bestVariant;
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
    final uri = lines.skip(i + 1).firstWhere((l) => l.isNotEmpty && !l.startsWith('#'), orElse: () => '');
    if (uri.isEmpty) continue;
    final bandwidth = int.tryParse(RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i])?.group(1) ?? '') ?? 1 << 40;
    if (bestBandwidth == null || bandwidth < bestBandwidth) {
      bestBandwidth = bandwidth;
      bestVariant = uri;
    }
  }
  if (bestVariant != null) return (uri: bestVariant, isPlaylist: true);
  final segment = lines.firstWhere((l) => l.isNotEmpty && !l.startsWith('#'), orElse: () => '');
  return segment.isEmpty ? null : (uri: segment, isPlaylist: segment.split('?').first.endsWith('.m3u8'));
}
