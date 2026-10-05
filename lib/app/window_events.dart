import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

/// org.couchbox.iptv on the session bus. On Wayland an app isn't told it was
/// minimized, so couchbox's KWin script (couchbox-home) calls Hidden when it
/// minimizes this window (long Home) and Shown when the window comes back.
class WindowEvents extends DBusObject {
  WindowEvents({required this.onHidden, required this.onShown}) : super(DBusObjectPath('/org/couchbox/iptv'));

  static const interface = 'org.couchbox.iptv.Window';

  final Future<void> Function() onHidden;
  final Future<void> Function() onShown;

  /// Takes the bus name and serves the object; logs and carries on when the
  /// name is taken (a second instance).
  static Future<void> register(WindowEvents events) async {
    final bus = DBusClient.session();
    try {
      final reply = await bus.requestName('org.couchbox.iptv', flags: {DBusRequestNameFlag.doNotQueue});
      if (reply != DBusRequestNameReply.primaryOwner && reply != DBusRequestNameReply.alreadyOwner) {
        debugPrint('window events: org.couchbox.iptv is taken ($reply)');
        return;
      }
      await bus.registerObject(events);
    } catch (e) {
      debugPrint('window events: $e');
    }
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != interface) return DBusMethodErrorResponse.unknownInterface();
    switch (methodCall.name) {
      case 'Hidden':
        await onHidden();
        return DBusMethodSuccessResponse();
      case 'Shown':
        await onShown();
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }
}
