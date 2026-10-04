import 'dart:io';

import 'package:flutter/services.dart';

/// Remote and keyboard keys, as they reach Flutter on couchbox (fire-blaster
/// remaps the remotes; see couchbox-base's fire-blaster.toml).
enum RemoteKey { up, down, left, right, ok, back, menu, info, channelUp, channelDown, stop, digit, other }

/// Set COUCHBOX_IPTV_KEYS=1 to log every key, to find out what a new remote
/// sends.
final _logKeys = Platform.environment['COUCHBOX_IPTV_KEYS'] == '1';

RemoteKey remoteKey(KeyEvent event) {
  final key = event.logicalKey;
  if (_logKeys) {
    // debugName is null in release builds; log the ids.
    stdout.writeln(
      'key ${event.runtimeType} logical=0x${key.keyId.toRadixString(16)} label="${key.keyLabel}" '
      'physical=0x${event.physicalKey.usbHidUsage.toRadixString(16)} character=${event.character}',
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
  // The MCE remote's More/Info (evdev KEY_INFO) has no XKB keysym Flutter
  // knows; its physical key is HID "Data On Screen" (PhysicalKeyboardKey.info).
  if (key == LogicalKeyboardKey.info ||
      event.physicalKey == PhysicalKeyboardKey.info ||
      key == LogicalKeyboardKey.keyI) {
    return RemoteKey.info;
  }
  if (key == LogicalKeyboardKey.channelUp || key == LogicalKeyboardKey.pageUp) return RemoteKey.channelUp;
  if (key == LogicalKeyboardKey.channelDown || key == LogicalKeyboardKey.pageDown) return RemoteKey.channelDown;
  if (key == LogicalKeyboardKey.mediaStop) return RemoteKey.stop;
  if (digitOf(event) != null) return RemoteKey.digit;
  return RemoteKey.other;
}

/// 0-9 from the number row or the keypad, else null.
int? digitOf(KeyEvent event) {
  final label = event.logicalKey.keyLabel;
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
  final i = numpad.indexOf(event.logicalKey);
  return i < 0 ? null : i;
}

/// Key down or auto-repeat: the events that move things.
bool isPress(KeyEvent event) => event is KeyDownEvent || event is KeyRepeatEvent;
