import 'dart:io';

import 'package:flutter/services.dart';

/// Remote and keyboard keys, as they reach Flutter on couchbox (fire-blaster
/// remaps the remotes; see couchbox-base's fire-blaster.toml).
enum RemoteKey {
  up,
  down,
  left,
  right,
  ok,
  back,
  menu,
  info,
  channelUp,
  channelDown,
  stop,
  playPause,
  play,
  pause,
  fastForward,
  rewind,
  next,
  previous,
  digit,
  other,
}

/// Set COUCHBOX_IPTV_KEYS=1 to log every key, to find out what a new remote
/// sends.
final _logKeys = Platform.environment['COUCHBOX_IPTV_KEYS'] == '1';

/// Remote keys XKB has no named keysym for (KEY_CHANNELUP, KEY_INFO,
/// KEY_NUMERIC_0, ...) get keysym 0x10081000 + their evdev code, which
/// Flutter's GTK embedder passes on as logical key 0x15_0000_0000 + keysym.
bool _isEvdev(LogicalKeyboardKey key, int evdevCode) => key.keyId == 0x1500000000 + 0x10081000 + evdevCode;

const _keyInfo = 0x166;
const _keyChannelUp = 0x192;
const _keyChannelDown = 0x193;
const _keyNumeric0 = 0x200;

RemoteKey remoteKey(KeyEvent event) {
  final key = event.logicalKey;
  final physical = event.physicalKey;
  if (_logKeys) {
    // debugName is null in release builds; log the ids.
    stdout.writeln(
      'key ${event.runtimeType} logical=0x${key.keyId.toRadixString(16)} label="${key.keyLabel}" '
      'physical=0x${physical.usbHidUsage.toRadixString(16)} character=${event.character}',
    );
  }
  if (key == LogicalKeyboardKey.arrowUp) return RemoteKey.up;
  if (key == LogicalKeyboardKey.arrowDown) return RemoteKey.down;
  if (key == LogicalKeyboardKey.arrowLeft) return RemoteKey.left;
  if (key == LogicalKeyboardKey.arrowRight) return RemoteKey.right;
  if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.select) {
    return RemoteKey.ok;
  }
  if (key == LogicalKeyboardKey.escape ||
      key == LogicalKeyboardKey.goBack ||
      key == LogicalKeyboardKey.browserBack ||
      key == LogicalKeyboardKey.backspace) {
    return RemoteKey.back;
  }
  if (key == LogicalKeyboardKey.contextMenu || key == LogicalKeyboardKey.keyM) return RemoteKey.menu;
  if (key == LogicalKeyboardKey.info ||
      physical == PhysicalKeyboardKey.info ||
      _isEvdev(key, _keyInfo) ||
      key == LogicalKeyboardKey.keyI) {
    return RemoteKey.info;
  }
  if (key == LogicalKeyboardKey.channelUp || _isEvdev(key, _keyChannelUp) || key == LogicalKeyboardKey.pageUp) {
    return RemoteKey.channelUp;
  }
  if (key == LogicalKeyboardKey.channelDown || _isEvdev(key, _keyChannelDown) || key == LogicalKeyboardKey.pageDown) {
    return RemoteKey.channelDown;
  }
  // KEY_STOPCD is XF86AudioStop; plain KEY_STOP is XKB's Cancel.
  if (key == LogicalKeyboardKey.mediaStop || key == LogicalKeyboardKey.cancel) return RemoteKey.stop;
  // XKB reports Play/Pause as XF86AudioPlay; the physical key tells them
  // apart (couchbox UPSTREAM-BUGS 17).
  if (key == LogicalKeyboardKey.mediaPlayPause || physical == PhysicalKeyboardKey.mediaPlayPause) {
    return RemoteKey.playPause;
  }
  if (key == LogicalKeyboardKey.mediaPlay) return RemoteKey.play;
  // The MCE remote's Pause is evdev KEY_PAUSE, the keyboard Pause key.
  if (key == LogicalKeyboardKey.mediaPause || key == LogicalKeyboardKey.pause) return RemoteKey.pause;
  if (key == LogicalKeyboardKey.mediaFastForward) return RemoteKey.fastForward;
  if (key == LogicalKeyboardKey.mediaRewind) return RemoteKey.rewind;
  if (key == LogicalKeyboardKey.mediaTrackNext) return RemoteKey.next;
  if (key == LogicalKeyboardKey.mediaTrackPrevious) return RemoteKey.previous;
  if (digitOf(event) != null) return RemoteKey.digit;
  return RemoteKey.other;
}

/// 0-9 from the number row, the keypad or a remote's number pad, else null.
int? digitOf(KeyEvent event) {
  final key = event.logicalKey;
  for (var d = 0; d <= 9; d++) {
    if (_isEvdev(key, _keyNumeric0 + d)) return d;
  }
  final label = key.keyLabel;
  if (label.length == 1 && label.codeUnitAt(0) >= 0x30 && label.codeUnitAt(0) <= 0x39) return int.parse(label);
  const numpad = [
    LogicalKeyboardKey.numpad0,
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
    LogicalKeyboardKey.numpad6,
    LogicalKeyboardKey.numpad7,
    LogicalKeyboardKey.numpad8,
    LogicalKeyboardKey.numpad9,
  ];
  final i = numpad.indexOf(key);
  return i < 0 ? null : i;
}

/// Key down or auto-repeat: the events that move things.
bool isPress(KeyEvent event) => event is KeyDownEvent || event is KeyRepeatEvent;
