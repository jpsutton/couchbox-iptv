import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Is something playing right now? Any PipeWire/PulseAudio output stream that
/// isn't paused (corked) counts: a video in this app, Plezy, Kodi or a browser.
abstract class PlaybackMonitor {
  bool get playing;
  void close();
}

/// Polls `pactl -f json list sink-inputs`. When pactl is missing or fails,
/// reports nothing playing.
class PactlPlaybackMonitor implements PlaybackMonitor {
  PactlPlaybackMonitor({Duration every = const Duration(seconds: 10)}) {
    _poll();
    _timer = Timer.periodic(every, (_) => _poll());
  }

  late final Timer _timer;
  bool _playing = false;

  @override
  bool get playing => _playing;

  Future<void> _poll() async {
    try {
      final result = await Process.run('pactl', ['-f', 'json', 'list', 'sink-inputs']);
      if (result.exitCode != 0) return;
      _playing = sinkInputsPlaying(result.stdout as String);
    } catch (_) {
      _playing = false;
    }
  }

  @override
  void close() => _timer.cancel();
}

/// True when [pactlJson] (pactl -f json list sink-inputs) lists a stream that
/// isn't corked.
bool sinkInputsPlaying(String pactlJson) {
  final inputs = jsonDecode(pactlJson);
  if (inputs is! List) return false;
  return inputs.any((input) => input is Map && input['corked'] == false);
}

class FixedPlaybackMonitor implements PlaybackMonitor {
  FixedPlaybackMonitor(this.playing);

  @override
  bool playing;

  @override
  void close() {}
}

/// Runs network jobs several at a time, and fewer, spaced out, while
/// something plays, so the job never competes with the stream on screen.
class Throttle {
  Throttle(
    this.monitor, {
    this.normal = 12,
    this.whilePlaying = 4,
    this.gapWhilePlaying = const Duration(milliseconds: 250),
  });

  final PlaybackMonitor monitor;
  final int normal;
  final int whilePlaying;
  final Duration gapWhilePlaying;
  int _running = 0;
  final _waiting = <Completer<void>>[];

  int get limit => monitor.playing ? whilePlaying : normal;

  Future<T> run<T>(Future<T> Function() job) async {
    while (_running >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      // Re-check now and then: the limit rises again when playback stops.
      await Future.any([turn.future, Future<void>.delayed(const Duration(seconds: 5))]);
      _waiting.remove(turn);
    }
    _running++;
    try {
      return await job();
    } finally {
      if (monitor.playing) await Future<void>.delayed(gapWhilePlaying);
      _running--;
      if (_waiting.isNotEmpty && !_waiting.first.isCompleted) _waiting.first.complete();
    }
  }

  /// Runs [job] for every item and waits for all of them.
  Future<void> forEach<E>(Iterable<E> items, Future<void> Function(E) job) =>
      Future.wait([for (final item in items) run(() => job(item))]);
}
