import 'package:couchbox_iptv/app/languages.dart';
import 'package:couchbox_iptv/app/repository.dart';
import 'package:couchbox_iptv/app/widgets.dart';
import 'package:couchbox_iptv/data/database.dart';
import 'package:couchbox_iptv/player/live_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

PlayableStream s(int id, String status, {DateTime? failed}) =>
    PlayableStream(id, 'u$id', const {}, status: status, playFailedAt: failed);

void main() {
  test('headers become mpv http-header-fields, commas escaped', () {
    expect(httpHeaderFields({}), '');
    expect(
      httpHeaderFields({'User-Agent': 'Mozilla/5.0 (X11, Linux)', 'Referer': 'https://example.com/'}),
      r'User-Agent: Mozilla/5.0 (X11\, Linux),Referer: https://example.com/',
    );
  });

  test('mpvLanguageList adds the other spellings', () {
    expect(mpvLanguageList(['eng']), 'eng,en');
    expect(mpvLanguageList(['spa', 'eng']), 'spa,es,eng,en');
    expect(mpvLanguageList(['xyz']), 'xyz');
    expect(mpvLanguageList([]), '');
  });

  test('orderForPlay: working, unchecked, dead, then recent playback failures', () {
    final now = DateTime(2026, 10, 4);
    final ordered = Repository.orderForPlay([
      s(1, 'working', failed: now.subtract(const Duration(days: 1))),
      s(2, 'dead'),
      s(3, 'unchecked'),
      s(4, 'working'),
      s(5, 'working', failed: now.subtract(const Duration(days: 30))),
    ], now);
    expect([for (final x in ordered) x.id], [4, 5, 3, 2, 1]);
  });

  test('nowAndNext and progress', () {
    Programme p(int h, String t) =>
        Programme(channelId: 'A', start: DateTime(2026, 10, 4, h), stop: DateTime(2026, 10, 4, h + 1), title: t);
    final list = [p(19, 'a'), p(20, 'b'), p(21, 'c')];
    final at = DateTime(2026, 10, 4, 20, 15);
    final (:now, :next) = nowAndNext(list, at);
    expect(now?.title, 'b');
    expect(next?.title, 'c');
    expect(progress(now!, at), 0.25);
    expect(nowAndNext(null, at).now, isNull);
  });

  test('a version 1 database gains the playback-failure columns', () {
    final raw = sqlite3.openInMemory();
    raw.execute('CREATE TABLE streams (id INTEGER PRIMARY KEY)');
    raw.execute('PRAGMA user_version = 1');
    // Re-open through IptvDatabase's migration path.
    final db = IptvDatabase.wrap(raw);
    final columns = [for (final r in db.db.select('PRAGMA table_info(streams)')) r['name']];
    expect(columns, containsAll(['play_failed_at', 'play_failure']));
    expect(db.db.select('PRAGMA user_version').first.columnAt(0), IptvDatabase.schemaVersion);
    db.close();
  });
}
