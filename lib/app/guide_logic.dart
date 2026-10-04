import '../data/database.dart';

/// The grid's columns are half hours.
const slot = Duration(minutes: 30);

/// [t] rounded down to its half hour.
DateTime floorToSlot(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute >= 30 ? 30 : 0);

/// The programme on at [t] in a time-ordered list, or null.
Programme? programmeAt(List<Programme>? programmes, DateTime t) {
  if (programmes == null) return null;
  for (final p in programmes) {
    if (!p.start.isAfter(t) && p.stop.isAfter(t)) return p;
    if (p.start.isAfter(t)) break;
  }
  return null;
}

/// Where the focus goes on Left ([direction] -1) or Right (+1) from [focus]:
/// the start of the neighbouring programme, or half an hour over where there
/// is no programme. Never before [earliest] (now: past programmes can't be
/// watched) nor after [latest].
DateTime stepFocus(
  List<Programme>? programmes,
  DateTime focus,
  int direction, {
  required DateTime earliest,
  required DateTime latest,
}) {
  final current = programmeAt(programmes, focus);
  DateTime target;
  if (direction > 0) {
    target = current?.stop ?? focus.add(slot);
    if (current == null) {
      // In a gap: stop at the next programme if it comes first.
      final next = programmes?.where((p) => p.start.isAfter(focus)).firstOrNull;
      if (next != null && next.start.isBefore(target)) target = next.start;
    }
  } else {
    target = (current?.start ?? focus).subtract(const Duration(minutes: 1));
    final landed = programmeAt(programmes, target);
    if (landed != null) {
      target = landed.start;
    } else {
      // A gap: half-hour steps, but not into the programme before it.
      target = floorToSlot(target);
      final before = programmeAt(programmes, target);
      if (before != null) target = before.stop;
    }
  }
  if (target.isBefore(earliest)) target = earliest;
  if (target.isAfter(latest)) target = latest;
  return target;
}

/// The first slot of the window that keeps [focus] visible, given the current
/// [windowStart] and [span]. Moves by whole slots; scrolling forward leaves
/// one more slot visible after the focus. Never before [earliest].
DateTime windowFor(DateTime focus, DateTime windowStart, Duration span, {required DateTime earliest}) {
  var start = windowStart;
  if (focus.isBefore(start)) start = floorToSlot(focus);
  final lastVisible = start.add(span).subtract(slot);
  if (!focus.isBefore(lastVisible.add(slot))) start = floorToSlot(focus).subtract(span).add(slot * 2);
  final floor = floorToSlot(earliest);
  return start.isBefore(floor) ? floor : start;
}
