import 'dart:async';

import 'package:couchbox_iptv/app/player_screen.dart';
import 'package:couchbox_iptv/app/repository.dart';
import 'package:couchbox_iptv/app/tuner.dart';
import 'package:couchbox_iptv/data/database.dart';
import 'package:couchbox_iptv/player/live_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shows a picture as soon as a stream opens.
class FakePlayer implements LivePlayer {
  final _status = StreamController<PlayerStatus>.broadcast();
  @override
  String get name => 'fake';
  @override
  Future<void> init() async {}
  @override
  Future<void> open(String url, {Map<String, String> headers = const {}}) async {
    _status.add(const PlayerStatus(PlayerPhase.opening));
    scheduleMicrotask(() => _status.add(const PlayerStatus(PlayerPhase.playing)));
  }

  @override
  Future<void> stop() async => _status.add(const PlayerStatus(PlayerPhase.idle));
  @override
  Future<void> setOption(String name, String value) async {}
  @override
  Future<void> command(List<String> args) async {}
  @override
  Future<void> redraw() async {}
  @override
  Stream<PlayerStatus> get status => _status.stream;
  @override
  Future<String?> property(String name) async => null;
  @override
  Widget view() => const SizedBox.expand();
  @override
  Future<void> dispose() async {}
}

void main() {
  late Repository repository;
  late Tuner tuner;
  late List<ChannelEntry> channels;

  setUp(() {
    final db = IptvDatabase.memory();
    db.db.execute("INSERT INTO channels (id, name, categories, languages) VALUES ('A.us', 'Alpha', '[]', '[]')");
    db.db.execute("INSERT INTO streams (id, channel_id, url, labels, rank) VALUES (1, 'A.us', 'u', '[]', 0)");
    repository = Repository(db);
    tuner = Tuner(FakePlayer(), repository);
    channels = [
      ChannelEntry(
        id: 'A.us',
        number: 1,
        name: 'Alpha',
        categories: const [],
        logoPath: null,
        favourite: false,
        streams: const [PlayableStream(1, 'u', {}, status: 'working')],
      ),
    ];
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Material(
        child: PlayerScreen(repository: repository, tuner: tuner, channels: channels, allChannels: channels, start: 0),
      ),
    ),
  );

  testWidgets('the banner hides 5 s after tuning', (tester) async {
    await pump(tester);
    await tester.pump(); // the first frame starts the tune
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(tuner.state.value.phase, PlayerPhase.playing);
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AnimatedOpacity), findsNothing);
  });

  testWidgets('the banner hides 5 s after arriving from the preview', (tester) async {
    await tester.runAsync(() => tuner.tune(channels.first));
    expect(tuner.state.value.phase, PlayerPhase.playing);
    await pump(tester);
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AnimatedOpacity), findsNothing);
  });

  testWidgets('Info hides and shows the banner at once', (tester) async {
    await tester.runAsync(() => tuner.tune(channels.first));
    await pump(tester);
    AnimatedOpacity banner() => tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    await tester.sendKeyEvent(LogicalKeyboardKey.info);
    await tester.pump();
    expect(find.byType(AnimatedOpacity), findsNothing); // gone at once
    await tester.sendKeyEvent(LogicalKeyboardKey.info);
    await tester.pump();
    expect(banner().opacity, 1);
    await tester.pump(const Duration(seconds: 5, milliseconds: 100));
    expect(banner().opacity, 0);
    expect(banner().duration, isNot(Duration.zero)); // the timeout fades
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AnimatedOpacity), findsNothing); // then leaves the tree
  });

  group('browsing with Channel Up/Down', () {
    late List<ChannelEntry> two;
    setUp(() {
      repository.database.db.execute(
        "INSERT INTO channels (id, name, categories, languages) VALUES ('B.us', 'Beta', '[]', '[]')",
      );
      repository.database.db.execute(
        "INSERT INTO streams (id, channel_id, url, labels, rank) VALUES (2, 'B.us', 'v', '[]', 0)",
      );
      two = [
        channels.first,
        ChannelEntry(
          id: 'B.us',
          number: 2,
          name: 'Beta',
          categories: const [],
          logoPath: null,
          favourite: false,
          streams: const [PlayableStream(2, 'v', {}, status: 'working')],
        ),
      ];
    });

    Future<void> start(WidgetTester tester) async {
      await tester.runAsync(() => tuner.tune(two.first));
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: PlayerScreen(repository: repository, tuner: tuner, channels: two, allChannels: two, start: 0),
          ),
        ),
      );
    }

    testWidgets('shows the next channel without tuning; OK tunes it', (tester) async {
      await start(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp); // Channel Up
      await tester.pump();
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Press OK to watch'), findsOneWidget);
      expect(tuner.state.value.channel?.id, 'A.us');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(tuner.state.value.channel?.id, 'B.us');
      expect(find.text('Press OK to watch'), findsNothing);
    });

    testWidgets('the timeout leaves the channel alone; the next press starts from it', (tester) async {
      await start(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pump();
      expect(find.text('Beta'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Beta'), findsNothing);
      expect(tuner.state.value.channel?.id, 'A.us');
      // From the playing channel again: Channel Down from Alpha wraps to Beta.
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('Info shows the playing channel', (tester) async {
      await start(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pump();
      expect(find.text('Beta'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.info);
      await tester.pump();
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsNothing);
    });
  });

  test('suspend stops the stream; resume retunes the same channel', () async {
    await tuner.tune(channels.first);
    expect(tuner.state.value.channel?.id, 'A.us');
    await tuner.suspend();
    expect(tuner.state.value.channel, isNull);
    await tuner.resume();
    expect(tuner.state.value.channel?.id, 'A.us');
    expect(tuner.state.value.phase, PlayerPhase.playing);
  });
}
