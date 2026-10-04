import 'dart:io';

/// XDG directories for couchbox-iptv.
class Paths {
  static String get _home => Platform.environment['HOME'] ?? '/tmp';

  static String _xdg(String variable, String fallback) {
    final value = Platform.environment[variable];
    return '${value == null || value.isEmpty ? '$_home/$fallback' : value}/couchbox-iptv';
  }

  /// settings.json
  static String get config => _xdg('XDG_CONFIG_HOME', '.config');

  /// iptv.db
  static String get data => _xdg('XDG_DATA_HOME', '.local/share');

  /// Downloaded API files and logos; safe to delete.
  static String get cache => _xdg('XDG_CACHE_HOME', '.cache');

  static String get database => '$data/iptv.db';
}
