import 'dart:io';

import 'package:args/args.dart';
import 'package:couchbox_iptv/data/database.dart';
import 'package:couchbox_iptv/paths.dart';
import 'package:couchbox_iptv/refresh/refresh.dart';
import 'package:couchbox_iptv/refresh/throttle.dart';
import 'package:couchbox_iptv/settings.dart';

/// couchbox-iptv-refresh: update the channel list, check the streams, fetch
/// the guide and logos. Run nightly by couchbox-iptv-refresh.timer, and by the
/// app when the filters change. Exits 0 when another run holds the lock.
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('catalog', defaultsTo: true, help: 'Download the iptv-org data and update the channel list')
    ..addFlag('check', defaultsTo: true, help: 'Check every stream')
    ..addFlag('guide', defaultsTo: true, help: 'Fetch the guide')
    ..addFlag('logos', defaultsTo: true, help: 'Download missing logos')
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults opts;
  try {
    opts = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${parser.usage}');
    exit(2);
  }
  if (opts.flag('help')) {
    stdout.writeln('Usage: couchbox-iptv-refresh [options]\n\n${parser.usage}');
    return;
  }

  Directory(Paths.data).createSync(recursive: true);
  final lock = File('${Paths.data}/refresh.lock').openSync(mode: FileMode.write);
  try {
    lock.lockSync(FileLock.exclusive);
  } on FileSystemException {
    stdout.writeln('another refresh is running');
    return;
  }

  final monitor = PactlPlaybackMonitor();
  final db = IptvDatabase.open(Paths.database);
  try {
    final ok = await Refresh(db, Settings.load(), Throttle(monitor)).run(
      RefreshOptions(
        catalog: opts.flag('catalog'),
        check: opts.flag('check'),
        guide: opts.flag('guide'),
        logos: opts.flag('logos'),
      ),
    );
    exitCode = ok ? 0 : 1;
  } finally {
    monitor.close();
    db.close();
    lock.unlockSync();
    lock.closeSync();
  }
}
