import 'package:couchbox_iptv/app/guide_logic.dart';
import 'package:couchbox_iptv/data/database.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime t(int h, [int m = 0]) => DateTime(2026, 10, 4, h, m);
Programme p(DateTime start, DateTime stop, String title) =>
    Programme(channelId: 'A', start: start, stop: stop, title: title);

void main() {
  // 20:00-21:00 a, 21:00-21:30 b, gap 21:30-22:30, 22:30-23:00 c
  final list = [p(t(20), t(21), 'a'), p(t(21), t(21, 30), 'b'), p(t(22, 30), t(23), 'c')];
  final earliest = t(20, 10);
  final latest = t(23, 59);
  DateTime right(DateTime f) => stepFocus(list, f, 1, earliest: earliest, latest: latest);
  DateTime left(DateTime f) => stepFocus(list, f, -1, earliest: earliest, latest: latest);

  test('floorToSlot', () {
    expect(floorToSlot(t(20, 29)), t(20));
    expect(floorToSlot(t(20, 30)), t(20, 30));
  });

  test('programmeAt', () {
    expect(programmeAt(list, t(20, 59))?.title, 'a');
    expect(programmeAt(list, t(21))?.title, 'b');
    expect(programmeAt(list, t(22)), isNull);
    expect(programmeAt(null, t(22)), isNull);
  });

  test('Right walks programmes, then half hours through a gap', () {
    expect(right(t(20, 10)), t(21));
    expect(right(t(21)), t(21, 30));
    expect(right(t(21, 30)), t(22));
    expect(right(t(22)), t(22, 30)); // the next programme comes first
    expect(right(t(22, 30)), t(23));
  });

  test('Left walks back, never before now', () {
    expect(left(t(22, 30)), t(22));
    expect(left(t(22)), t(21, 30));
    expect(left(t(21, 30)), t(21));
    expect(left(t(21)), earliest); // a started before now
  });

  test('no guide: half-hour steps', () {
    expect(stepFocus(null, t(21), 1, earliest: earliest, latest: latest), t(21, 30));
    expect(stepFocus(null, t(21), -1, earliest: earliest, latest: latest), t(20, 30));
  });

  test('windowFor keeps the focus visible, in whole slots, never before now', () {
    const span = Duration(hours: 3);
    expect(windowFor(t(21), t(20), span, earliest: t(20, 10)), t(20));
    expect(windowFor(t(23, 15), t(20), span, earliest: t(20, 10)), t(21)); // one more slot after the focus
    expect(windowFor(t(20, 10), t(21, 30), span, earliest: t(20, 10)), t(20));
  });
}
