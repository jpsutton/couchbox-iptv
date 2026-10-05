import 'dart:async';

import 'package:flutter/foundation.dart';

import '../player/live_player.dart';
import '../settings.dart';
import 'languages.dart';
import 'repository.dart';

/// What the tuner is doing, for the player screen.
class TunerState {
  const TunerState({this.channel, this.stream, this.attempt = 0, this.phase = PlayerPhase.idle, this.message});

  final ChannelEntry? channel;
  final PlayableStream? stream;

  /// 1-based index into the channel's streams.
  final int attempt;
  final PlayerPhase phase;
  final String? message;
}

/// Tunes channels on a [LivePlayer]: tries a channel's streams in order until
/// one shows a picture, and tells the repository which ones fail.
class Tuner {
  Tuner(this.player, this.repository, {this.tuneTimeout = const Duration(seconds: 15)});

  final LivePlayer player;
  final Repository repository;
  final Duration tuneTimeout;
  final state = ValueNotifier(const TunerState());
  int _generation = 0;

  /// Paused by the viewer (the cache keeps filling).
  final paused = ValueNotifier(false);

  /// Applies the preferred audio and subtitle languages.
  Future<void> configure(Settings settings) async {
    await player.init();
    await player.setOption('alang', mpvLanguageList(settings.audioLanguages));
    await player.setOption('slang', mpvLanguageList(settings.subtitleLanguages));
    // No subtitles unless asked for (forced ones still show).
    await player.setOption('sid', settings.subtitleLanguages.isEmpty ? 'no' : 'auto');
  }

  /// Tunes [channel], starting with its stream at [from] (to skip to the
  /// next stream after a bad picture).
  Future<void> tune(ChannelEntry channel, {int from = 0}) async {
    final generation = ++_generation;
    if (paused.value) {
      paused.value = false;
      await player.setOption('pause', 'no');
    }
    repository.lastChannel = channel.id;
    final streams = channel.streams;
    for (var i = from; i < streams.length; i++) {
      final stream = streams[i];
      state.value = TunerState(channel: channel, stream: stream, attempt: i + 1, phase: PlayerPhase.opening);
      final result = await _try(stream);
      if (generation != _generation) return; // Another tune took over.
      if (result.phase == PlayerPhase.playing) {
        repository.recordPlaySuccess(stream.id);
        state.value = TunerState(channel: channel, stream: stream, attempt: i + 1, phase: PlayerPhase.playing);
        return;
      }
      repository.recordPlayFailure(stream.id, result.error ?? 'failed');
    }
    if (generation != _generation) return;
    await player.stop();
    state.value = TunerState(
      channel: channel,
      phase: PlayerPhase.failed,
      message: streams.isEmpty ? 'No streams for this channel' : 'None of the ${streams.length} streams played',
    );
  }

  /// Gives up on the current stream and tries the channel's next one.
  Future<void> nextStream() async {
    final current = state.value;
    if (current.channel == null) return;
    if (current.stream != null) repository.recordPlayFailure(current.stream!.id, 'skipped by the viewer');
    await tune(current.channel!, from: current.attempt);
  }

  Future<PlayerStatus> _try(PlayableStream stream) async {
    final done = Completer<PlayerStatus>();
    final sub = player.status.listen((s) {
      if (!done.isCompleted && (s.phase == PlayerPhase.playing || s.phase == PlayerPhase.failed)) done.complete(s);
    });
    try {
      await player.open(stream.url, headers: stream.headers);
      return await done.future.timeout(
        tuneTimeout,
        onTimeout: () => const PlayerStatus(PlayerPhase.failed, 'no picture within 15 s'),
      );
    } catch (e) {
      return PlayerStatus(PlayerPhase.failed, e.toString());
    } finally {
      await sub.cancel();
    }
  }

  Future<void> setPaused(bool value) async {
    if (state.value.phase != PlayerPhase.playing) return;
    paused.value = value;
    await player.setOption('pause', value ? 'yes' : 'no');
  }

  /// How far playback is behind the live edge (the end of the cache), in
  /// seconds; null when unknown.
  Future<double?> behindLive() async {
    final position = double.tryParse(await player.property('time-pos') ?? '');
    final cached = double.tryParse(await player.property('demuxer-cache-time') ?? '');
    if (position == null || cached == null) return null;
    final behind = cached - position;
    return behind < 0 ? 0 : behind;
  }

  /// Rewind ([seconds] < 0) within the cache, or fast forward towards live:
  /// never past the live edge, less a few seconds so playback doesn't stall.
  Future<void> seekBy(int seconds) async {
    if (state.value.phase != PlayerPhase.playing) return;
    var by = seconds.toDouble();
    if (by > 0) {
      final behind = await behindLive() ?? 0;
      by = by.clamp(0, behind - 3 > 0 ? behind - 3 : 0);
      if (by <= 0) return;
    }
    await player.command(['seek', by.toStringAsFixed(1), 'relative']);
  }

  ChannelEntry? _suspended;

  /// The app went out of sight (minimized, or the home screen over it):
  /// stop the stream, to [resume] the same channel when it comes back.
  Future<void> suspend() async {
    final channel = state.value.channel;
    if (channel == null) return;
    _suspended = channel;
    await stop();
  }

  Future<void> resume() async {
    final channel = _suspended;
    _suspended = null;
    if (channel != null && state.value.channel == null) await tune(channel);
  }

  Future<void> stop() async {
    _generation++;
    paused.value = false;
    await player.stop();
    state.value = const TunerState();
  }
}
