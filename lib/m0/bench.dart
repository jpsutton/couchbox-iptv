import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../player/live_player.dart';

/// One test stream (assets/m0_streams.json).
class TestStream {
  TestStream.fromJson(Map<String, dynamic> json)
    : name = json['name'] as String,
      url = json['url'] as String,
      headers = (json['headers'] as Map? ?? {}).cast<String, String>();

  final String name;
  final String url;
  final Map<String, String> headers;
}

/// What one backend did with one stream.
class BenchResult {
  BenchResult(this.backend, this.stream);

  final String backend;
  final String stream;
  int? tuneMs;
  String? error;
  double? cpuPercent;
  int? droppedFrames;
  int? decoderDrops;
  String? hwdec;
  String? codec;
  String? size;
  String? fps;

  Map<String, Object?> toJson() => {
    'backend': backend,
    'stream': stream,
    'tune_ms': tuneMs,
    'error': error,
    'cpu_percent': cpuPercent,
    'dropped_frames': droppedFrames,
    'decoder_drops': decoderDrops,
    'hwdec': hwdec,
    'codec': codec,
    'size': size,
    'fps': fps,
  };

  @override
  String toString() => jsonEncode(toJson());
}

/// CPU time used by this process (mpv runs in it for both backends), in
/// seconds, from /proc/self/stat (utime + stime, at 100 ticks a second).
double processCpuSeconds() {
  final stat = File('/proc/self/stat').readAsStringSync();
  // Fields after the parenthesised command name, which may contain spaces.
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return (int.parse(fields[11]) + int.parse(fields[12])) / 100.0;
}

/// Tunes [stream] on [player] and watches it for [watch].
Future<BenchResult> benchOne(
  LivePlayer player,
  TestStream stream, {
  Duration tuneTimeout = const Duration(seconds: 20),
  Duration watch = const Duration(seconds: 20),
}) async {
  final result = BenchResult(player.name, stream.name);
  final tuned = Completer<PlayerStatus>();
  final sub = player.status.listen((s) {
    if (!tuned.isCompleted && (s.phase == PlayerPhase.playing || s.phase == PlayerPhase.failed)) {
      tuned.complete(s);
    }
  });
  final clock = Stopwatch()..start();
  try {
    await player.open(stream.url, headers: stream.headers);
    final status = await tuned.future.timeout(
      tuneTimeout,
      onTimeout: () => const PlayerStatus(PlayerPhase.failed, 'no picture within the timeout'),
    );
    if (status.phase == PlayerPhase.failed) {
      result.error = status.error;
      return result;
    }
    result.tuneMs = clock.elapsedMilliseconds;

    final drops0 = int.tryParse(await player.property('frame-drop-count') ?? '') ?? 0;
    final decoderDrops0 = int.tryParse(await player.property('decoder-frame-drop-count') ?? '') ?? 0;
    final cpu0 = processCpuSeconds();
    final wall = Stopwatch()..start();
    await Future<void>.delayed(watch);
    result.cpuPercent = (processCpuSeconds() - cpu0) / (wall.elapsedMilliseconds / 1000) * 100;
    result.droppedFrames = (int.tryParse(await player.property('frame-drop-count') ?? '') ?? 0) - drops0;
    result.decoderDrops = (int.tryParse(await player.property('decoder-frame-drop-count') ?? '') ?? 0) - decoderDrops0;
    result.hwdec = await player.property('hwdec-current');
    result.codec = await player.property('video-codec');
    final w = await player.property('video-params/w');
    final h = await player.property('video-params/h');
    result.size = w == null ? null : '${w}x$h';
    result.fps = await player.property('container-fps');
    return result;
  } catch (e) {
    result.error = e.toString();
    return result;
  } finally {
    await sub.cancel();
    await player.stop();
  }
}

/// Where the M0 results are written.
File resultsFile() {
  final home = Platform.environment['HOME'] ?? '/tmp';
  final dataHome = Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
  return File('$dataHome/couchbox-iptv/m0-results.json');
}

void saveResults(List<BenchResult> results) {
  final file = resultsFile();
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results.map((r) => r.toJson()).toList()));
}
