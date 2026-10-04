import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'live_player.dart';

/// mpv rendering into a Flutter texture through media_kit. The picture is an
/// ordinary widget, at the cost of a copy into Flutter's GL context.
class MediaKitPlayer implements LivePlayer {
  Player? _player;
  VideoController? _controller;
  final _status = StreamController<PlayerStatus>.broadcast();
  final _subs = <StreamSubscription<dynamic>>[];
  bool _opening = false;

  @override
  String get name => 'media_kit';

  @override
  Stream<PlayerStatus> get status => _status.stream;

  NativePlayer get _native => _player!.platform as NativePlayer;

  @override
  Future<void> init() async {
    if (_player != null) return;
    MediaKit.ensureInitialized();
    final player = Player(configuration: const PlayerConfiguration(title: 'IPTV'));
    _player = player;
    _controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(enableHardwareAcceleration: true),
    );
    for (final option in liveMpvOptions.entries) {
      await _native.setProperty(option.key, option.value);
    }
    // The first frame: video size known and playing (not buffering).
    _subs.add(player.stream.width.listen((_) => _checkPlaying()));
    _subs.add(player.stream.buffering.listen((_) => _checkPlaying()));
    _subs.add(player.stream.error.listen((e) => _status.add(PlayerStatus(PlayerPhase.failed, e))));
  }

  void _checkPlaying() {
    final player = _player;
    if (!_opening || player == null) return;
    if ((player.state.width ?? 0) > 0 && !player.state.buffering) {
      _opening = false;
      _status.add(const PlayerStatus(PlayerPhase.playing));
    }
  }

  @override
  Future<void> open(String url, {Map<String, String> headers = const {}}) async {
    await init();
    _opening = true;
    _status.add(const PlayerStatus(PlayerPhase.opening));
    await _player!.open(Media(url, httpHeaders: headers));
  }

  @override
  Future<void> stop() async {
    _opening = false;
    await _player?.stop();
    _status.add(const PlayerStatus(PlayerPhase.idle));
  }

  @override
  Future<String?> property(String name) async {
    if (_player == null) return null;
    try {
      final value = await _native.getProperty(name);
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget view() {
    final controller = _controller;
    if (controller == null) return const SizedBox.expand();
    return Video(controller: controller, controls: NoVideoControls, fill: const Color(0xFF000000));
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    await _player?.dispose();
    _player = null;
    await _status.close();
  }
}
