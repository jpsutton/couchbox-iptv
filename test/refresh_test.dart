import 'dart:async';

import 'package:couchbox_iptv/data/database.dart';
import 'package:couchbox_iptv/data/models.dart';
import 'package:couchbox_iptv/data/selection.dart';
import 'package:couchbox_iptv/refresh/guides.dart';
import 'package:couchbox_iptv/refresh/stream_check.dart';
import 'package:couchbox_iptv/refresh/throttle.dart';
import 'package:couchbox_iptv/settings.dart';
import 'package:flutter_test/flutter_test.dart';

ApiChannel channel(
  String id, {
  String country = 'US',
  List<String> categories = const ['news'],
  bool nsfw = false,
  String? closed,
}) => ApiChannel.fromJson({
  'id': id,
  'name': id.split('.').first,
  'country': country,
  'categories': categories,
  'is_nsfw': nsfw,
  'closed': closed,
});

ApiStream stream(String channel, String url, {String? quality, List<String> labels = const [], String? feed}) =>
    ApiStream.fromJson({'channel': channel, 'feed': feed, 'url': url, 'quality': quality, 'labels': labels});

ApiFeed feed(String channel, List<String> languages, {String id = 'SD'}) =>
    ApiFeed.fromJson({'channel': channel, 'id': id, 'is_main': true, 'languages': languages});

Catalog catalog({
  required List<ApiChannel> channels,
  required List<ApiStream> streams,
  List<ApiFeed> feeds = const [],
  List<String> blocked = const [],
}) => Catalog(
  channels: channels,
  feeds: feeds,
  streams: streams,
  logos: const [],
  blocklist: [
    for (final b in blocked) ApiBlock.fromJson({'channel': b}),
  ],
);

void main() {
  group('select', () {
    test('filters by country, language and category, and always drops unsafe channels', () {
      final c = catalog(
        channels: [
          channel('News.us'),
          channel('Sport.us', categories: ['sports']),
          channel('Uk.uk', country: 'GB'),
          channel('Spanish.us'),
          channel('Unknown.us'),
          channel('Adult.us', nsfw: true),
          channel('Blocked.us'),
          channel('Closed.us', closed: '2024-01-01'),
          channel('NoStreams.us'),
        ],
        feeds: [
          feed('News.us', ['eng']),
          feed('Sport.us', ['eng']),
          feed('Spanish.us', ['spa']),
        ],
        streams: [
          for (final id in [
            'News.us',
            'Sport.us',
            'Uk.uk',
            'Spanish.us',
            'Unknown.us',
            'Adult.us',
            'Blocked.us',
            'Closed.us',
          ])
            stream(id, 'https://example.com/$id.m3u8'),
        ],
        blocked: ['Blocked.us'],
      );
      List<String> ids(Settings s) => [for (final x in select(c, s)) x.channel.id];

      expect(ids(const Settings()), ['News.us', 'Sport.us', 'Unknown.us']);
      expect(ids(const Settings(categories: ['sports'])), ['Sport.us']);
      expect(ids(const Settings(countries: [], languages: [])), [
        'News.us',
        'Spanish.us',
        'Sport.us',
        'Uk.uk',
        'Unknown.us',
      ]);
    });

    test('takes the Pluto id from a jmp2.uk link', () {
      final c = catalog(
        channels: [channel('Fox.us')],
        streams: [
          stream('Fox.us', 'https://example.com/fox.m3u8', quality: '1080p'),
          stream('Fox.us', 'https://jmp2.uk/plu-640a68880e884c0009979cc2.m3u8', quality: '720p'),
        ],
      );
      expect(select(c, const Settings()).single.plutoId, '640a68880e884c0009979cc2');
    });
  });

  test('rankStreams: unlabelled first, then by resolution up to 1080, then original order', () {
    final ranked = rankStreams([
      stream('A', 'geo-1080', quality: '1080p', labels: ['Geo-blocked']),
      stream('A', 'part-1080', quality: '1080p', labels: ['Not 24/7']),
      stream('A', '720', quality: '720p'),
      stream('A', '2160', quality: '2160p'),
      stream('A', '1080', quality: '1080p'),
      stream('A', 'unknown'),
    ]);
    expect([for (final s in ranked) s.url], ['2160', '1080', '720', 'unknown', 'part-1080', 'geo-1080']);
  });

  test('bestLogo prefers a channel-wide PNG near 256 px, never SVG', () {
    ApiLogo logo(String url, {String? feed, int width = 256, String format = 'PNG', bool inUse = true}) =>
        ApiLogo.fromJson({'channel': 'A', 'feed': feed, 'in_use': inUse, 'width': width, 'format': format, 'url': url});
    expect(
      bestLogo([
        logo('svg', format: 'SVG'),
        logo('feed', feed: 'SD'),
        logo('big', width: 2000),
        logo('good', width: 300),
      ])?.url,
      'good',
    );
    expect(bestLogo([logo('svg', format: 'SVG')]), isNull);
    expect(bestLogo(null), isNull);
  });

  test('nextHlsUri: lowest-bandwidth variant, else the first segment', () {
    expect(
      nextHlsUri(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=5000000\nhi.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nlo.m3u8\n',
      ),
      (uri: 'lo.m3u8', isPlaylist: true),
    );
    expect(nextHlsUri('#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg1.ts?x=1\n#EXTINF:6.0,\nseg2.ts\n'), (
      uri: 'seg1.ts?x=1',
      isPlaylist: false,
    ));
    expect(nextHlsUri('#EXTM3U\n#EXT-X-ENDLIST\n'), isNull);
  });

  group('XMLTV', () {
    test('times are converted to UTC', () {
      expect(parseXmltvTime('20261004213000 +0000'), DateTime.utc(2026, 10, 4, 21, 30));
      expect(parseXmltvTime('20261004213000 -0500'), DateTime.utc(2026, 10, 5, 2, 30));
      expect(parseXmltvTime('202610042130'), DateTime.utc(2026, 10, 4, 21, 30));
      expect(parseXmltvTime('junk'), isNull);
    });

    test('keeps wanted channels inside the window, for every channel sharing a guide id', () async {
      const xml = '''<?xml version="1.0"?><tv>
<channel id="p1"><display-name>One</display-name></channel>
<programme start="20261004200000 +0000" stop="20261004210000 +0000" channel="p1"><title>Old</title></programme>
<programme start="20261004220000 +0000" stop="20261004230000 +0000" channel="p1"><title lang="en">News at 10</title><sub-title>Late</sub-title><desc>Headlines.</desc><category>News</category></programme>
<programme start="20261004220000 +0000" stop="20261004230000 +0000" channel="p2"><title>Other</title></programme>
</tv>''';
      final programmes = await parseXmltv(
        Stream.value(xml),
        {
          'p1': ['A.us', 'B.us'],
        },
        from: DateTime.utc(2026, 10, 4, 21, 30),
        until: DateTime.utc(2026, 10, 5),
      );
      expect([for (final p in programmes) '${p.channelId} ${p.title}'], ['A.us News at 10', 'B.us News at 10']);
      expect(programmes.first.subtitle, 'Late');
      expect(programmes.first.description, 'Headlines.');
      expect(programmes.first.category, 'News');
    });
  });

  test('sinkInputsPlaying: an uncorked stream counts, a corked one does not', () {
    expect(sinkInputsPlaying('[]'), isFalse);
    expect(sinkInputsPlaying('[{"index":1,"corked":true}]'), isFalse);
    expect(sinkInputsPlaying('[{"index":1,"corked":true},{"index":2,"corked":false}]'), isTrue);
  });

  test('Throttle runs fewer jobs at once while something plays', () async {
    final monitor = FixedPlaybackMonitor(false);
    final throttle = Throttle(monitor, normal: 3, whilePlaying: 1, gapWhilePlaying: Duration.zero);
    var running = 0, peak = 0;
    Future<void> job(int _) async {
      running++;
      peak = running > peak ? running : peak;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      running--;
    }

    await throttle.forEach(List.generate(10, (i) => i), job);
    expect(peak, 3);
    monitor.playing = true;
    peak = 0;
    await throttle.forEach(List.generate(4, (i) => i), job);
    expect(peak, 1);
  });

  group('database', () {
    late IptvDatabase db;
    setUp(() => db = IptvDatabase.memory());
    tearDown(() => db.close());

    List<SelectedChannel> chans(List<String> ids) => select(
      catalog(
        channels: [for (final id in ids) channel(id)],
        streams: [for (final id in ids) stream(id, 'https://example.com/$id.m3u8')],
      ),
      const Settings(),
    );

    test('channel numbers stay put as channels come and go', () {
      db.replaceChannels(chans(['B.us', 'A.us']));
      Map<String, int> numbers() => {
        for (final r in db.db.select('SELECT channel_id, number FROM numbers'))
          r['channel_id'] as String: r['number'] as int,
      };
      expect(numbers(), {'A.us': 1, 'B.us': 2});
      db.replaceChannels(chans(['B.us', 'C.us']));
      expect(numbers(), {'A.us': 1, 'B.us': 2, 'C.us': 3});
      db.replaceChannels(chans(['A.us', 'C.us']));
      expect(numbers()['A.us'], 1);
      expect([for (final r in db.db.select('SELECT id FROM channels ORDER BY id')) r['id']], ['A.us', 'C.us']);
    });

    test('a stream keeps its health across refreshes; programmes go with their channel', () {
      db.replaceChannels(chans(['A.us', 'B.us']));
      final a = db.streamsToCheck().firstWhere((s) => s.channelId == 'A.us');
      db.recordHealth(a.id, const StreamHealth.ok(120), DateTime(2026, 10, 4));
      db.replaceProgrammes(
        ['A.us', 'B.us'],
        [
          Programme(
            channelId: 'B.us',
            start: DateTime.utc(2026, 10, 4, 20),
            stop: DateTime.utc(2026, 10, 4, 21),
            title: 'Show',
          ),
        ],
      );
      db.replaceChannels(chans(['A.us']));
      expect(db.db.select('SELECT status, response_ms FROM streams').single, {'status': 'working', 'response_ms': 120});
      expect(db.counts(), {'channels': 1, 'programmes': 0, 'streams_working': 1});
      // Unchecked streams come first; recent checks are skipped on resume.
      db.replaceChannels(chans(['A.us', 'C.us']));
      expect(db.streamsToCheck().first.channelId, 'C.us');
      expect([for (final s in db.streamsToCheck(since: DateTime(2026, 10, 3))) s.channelId], ['C.us']);
      expect([for (final s in db.streamsToCheck(since: DateTime(2026, 10, 5))) s.channelId], ['C.us', 'A.us']);
    });
  });
}
