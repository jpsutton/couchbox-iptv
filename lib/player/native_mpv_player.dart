import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'live_player.dart';

/// mpv drawing into a Wayland subsurface below the window (the plugin
/// vendored from Plezy, linux/runner/mpv). Video reaches the compositor
/// without a copy through Flutter; the widget only tells the plugin where the
/// picture goes and leaves that area transparent.
class NativeMpvPlayer implements LivePlayer {
  static const _methods = MethodChannel('org.couchbox.iptv/mpv');
  static const _events = EventChannel('org.couchbox.iptv/mpv/events');

  final _status = StreamController<PlayerStatus>.broadcast();
  StreamSubscription<dynamic>? _eventSub;
  bool _initialized = false;

  @override
  String get name => 'native';

  @override
  Stream<PlayerStatus> get status => _status.stream;

  @override
  Future<void> init() async {
    if (_initialized) return;
    // Listen first: events for the first file must not be missed.
    _eventSub = _events.receiveBroadcastStream().listen(_onEvent);
    final ok = await _methods.invokeMethod<bool>('initialize', {'hardwareDecoding': true});
    if (ok != true) throw StateError('mpv plugin did not initialize');
    for (final option in liveMpvOptions.entries) {
      await _setProperty(option.key, option.value);
    }
    _initialized = true;
  }

  void _onEvent(dynamic event) {
    // Property changes arrive as lists; only named events matter here.
    if (event is! Map || event['type'] != 'event') return;
    switch (event['name']) {
      case 'playback-restart':
        _status.add(const PlayerStatus(PlayerPhase.playing));
      case 'end-file':
        final data = event['data'];
        // MPV_END_FILE_REASON_ERROR
        if (data is Map && data['reason'] == 4) {
          _status.add(PlayerStatus(PlayerPhase.failed, 'mpv error ${data['error']}'));
        }
    }
  }

  Future<void> _setProperty(String name, String value) =>
      _methods.invokeMethod('setProperty', {'name': name, 'value': value});

  @override
  Future<void> setOption(String name, String value) async {
    await init();
    await _setProperty(name, value);
  }

  @override
  Future<void> open(String url, {Map<String, String> headers = const {}}) async {
    await init();
    await _setProperty('http-header-fields', httpHeaderFields(headers));
    _status.add(const PlayerStatus(PlayerPhase.opening));
    await _methods.invokeMethod('command', {
      'args': ['loadfile', url, 'replace'],
    });
    await _methods.invokeMethod('setVisible', {'visible': true});
  }

  @override
  Future<void> stop() async {
    if (!_initialized) return;
    await _methods.invokeMethod('command', {
      'args': ['stop'],
    });
    await _methods.invokeMethod('setVisible', {'visible': false});
    _status.add(const PlayerStatus(PlayerPhase.idle));
  }

  @override
  Future<String?> property(String name) async {
    if (!_initialized) return null;
    try {
      return await _methods.invokeMethod<String>('getProperty', {'name': name});
    } on PlatformException {
      return null;
    }
  }

  @override
  Widget view() => const _VideoPlane();

  @override
  Future<void> dispose() async {
    await _eventSub?.cancel();
    if (_initialized) await _methods.invokeMethod('dispose');
    _initialized = false;
    await _status.close();
  }

  static Future<void> setVideoRect(Rect physical, double devicePixelRatio) => _methods.invokeMethod('setVideoRect', {
    'left': physical.left.floor(),
    'top': physical.top.floor(),
    'right': physical.right.ceil(),
    'bottom': physical.bottom.ceil(),
    'devicePixelRatio': devicePixelRatio,
  });
}

/// A transparent box whose screen position, in physical pixels, is sent to
/// the plugin after every layout that moves it (as Plezy's Video widget does).
class _VideoPlane extends StatefulWidget {
  const _VideoPlane();

  @override
  State<_VideoPlane> createState() => _VideoPlaneState();
}

class _VideoPlaneState extends State<_VideoPlane> {
  Rect? _sent;

  void _sendRect() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final rect = (box.localToGlobal(Offset.zero) & box.size);
    final physical = Rect.fromLTRB(rect.left * dpr, rect.top * dpr, rect.right * dpr, rect.bottom * dpr);
    if (physical == _sent) return;
    _sent = physical;
    NativeMpvPlayer.setVideoRect(physical, dpr);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _sendRect());
        return const SizedBox.expand();
      },
    );
  }
}
