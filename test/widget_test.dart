import 'package:couchbox_iptv/m0/bench.dart';
import 'package:couchbox_iptv/player/live_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('headers become mpv http-header-fields, commas escaped', () {
    expect(httpHeaderFields({}), '');
    expect(
      httpHeaderFields({'User-Agent': 'Mozilla/5.0 (X11, Linux)', 'Referer': 'https://example.com/'}),
      r'User-Agent: Mozilla/5.0 (X11\, Linux),Referer: https://example.com/',
    );
  });

  test('test streams read their headers', () {
    final stream = TestStream.fromJson({
      'name': 'A',
      'url': 'https://example.com/a.m3u8',
      'headers': {'Referer': 'https://example.com/'},
    });
    expect(stream.headers, {'Referer': 'https://example.com/'});
    expect(TestStream.fromJson({'name': 'B', 'url': 'u'}).headers, isEmpty);
  });
}
