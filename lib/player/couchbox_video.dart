import 'dart:io';

/// The mpv settings couchbox-video-profile leaves in ~/.config/couchboxrc
/// [Video] for boards whose decoders mpv's defaults miss (the Raspberry Pi's
/// V4L2 decoders: Hwdec=drm,v4l2m2m, VideoSync=audio). Absent elsewhere,
/// so other boxes keep [liveMpvOptions] as they are.
Map<String, String> couchboxMpvOptions({String? configText}) {
  String? text = configText;
  if (text == null) {
    final env = Platform.environment;
    final xdg = env['XDG_CONFIG_HOME'];
    final base = xdg != null && xdg.isNotEmpty ? xdg : '${env['HOME'] ?? '/tmp'}/.config';
    try {
      text = File('$base/couchboxrc').readAsStringSync();
    } catch (_) {
      return const {};
    }
  }
  final video = <String, String>{};
  var inVideo = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('[')) {
      inVideo = line == '[Video]';
    } else if (inVideo && line.contains('=') && !line.startsWith('#')) {
      final i = line.indexOf('=');
      video[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
  }
  return {
    if (video['Hwdec']?.isNotEmpty == true) 'hwdec': video['Hwdec']!,
    if (video['VideoSync']?.isNotEmpty == true) 'video-sync': video['VideoSync']!,
  };
}
