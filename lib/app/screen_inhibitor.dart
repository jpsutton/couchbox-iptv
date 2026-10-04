import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import '../player/live_player.dart';
import 'tuner.dart';

/// Keeps the screen on while a stream plays (full screen or in the guide's
/// preview) and isn't paused, through org.freedesktop.ScreenSaver.Inhibit,
/// which Plasma's PowerDevil honours for turning the display off. The
/// inhibition lasts as long as this process's bus connection, so a crash
/// can't leave the screen on for good.
class ScreenInhibitor {
  ScreenInhibitor(this.tuner) {
    tuner.state.addListener(_update);
    tuner.paused.addListener(_update);
  }

  final Tuner tuner;
  final _bus = DBusClient.session();
  int? _cookie;
  Future<void> _pending = Future.value();

  DBusRemoteObject get _screenSaver =>
      DBusRemoteObject(_bus, name: 'org.freedesktop.ScreenSaver', path: DBusObjectPath('/org/freedesktop/ScreenSaver'));

  void _update() {
    final want = tuner.state.value.phase == PlayerPhase.playing && !tuner.paused.value;
    // One call at a time, in order.
    _pending = _pending.then((_) => _set(want));
  }

  Future<void> _set(bool on) async {
    try {
      if (on && _cookie == null) {
        final reply = await _screenSaver.callMethod('org.freedesktop.ScreenSaver', 'Inhibit', [
          const DBusString('couchbox-iptv'),
          const DBusString('Playing live TV'),
        ], replySignature: DBusSignature('u'));
        _cookie = reply.returnValues.first.asUint32();
      } else if (!on && _cookie != null) {
        final cookie = _cookie!;
        _cookie = null;
        await _screenSaver.callMethod('org.freedesktop.ScreenSaver', 'UnInhibit', [
          DBusUint32(cookie),
        ], replySignature: DBusSignature(''));
      }
    } catch (e) {
      debugPrint('screen inhibit: $e');
    }
  }

  Future<void> close() async {
    tuner.state.removeListener(_update);
    tuner.paused.removeListener(_update);
    await _pending;
    await _bus.close();
  }
}
