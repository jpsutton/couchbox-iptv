import 'package:couchbox_iptv/player/couchbox_video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('couchboxrc [Video] Hwdec and VideoSync become mpv options', () {
    const rc = '[Video]\nPlezyScaling=fast\nHwdec=drm,v4l2m2m\nVideoSync=audio\n\n[Hardware]\nHwdec=ignored\n';
    expect(couchboxMpvOptions(configText: rc), {'hwdec': 'drm,v4l2m2m', 'video-sync': 'audio'});
  });

  test('no couchbox settings, no overrides', () {
    expect(couchboxMpvOptions(configText: '[Video]\nTranscodeHEVC=false\n'), isEmpty);
    expect(couchboxMpvOptions(configText: ''), isEmpty);
  });
}
