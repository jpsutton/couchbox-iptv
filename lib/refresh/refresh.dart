import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/database.dart';
import '../data/models.dart';
import '../data/selection.dart';
import '../paths.dart';
import '../settings.dart';
import 'guides.dart';
import 'http.dart';
import 'stream_check.dart';
import 'throttle.dart';

const apiBase = 'https://iptv-org.github.io/api';

/// What a run does; all on by default.
class RefreshOptions {
  const RefreshOptions({
    this.catalog = true,
    this.check = true,
    this.guide = true,
    this.logos = true,
    this.recheckAfter = const Duration(hours: 12),
  });

  final bool catalog;
  final bool check;
  final bool guide;
  final bool logos;

  /// Streams checked more recently than this are skipped, so a stopped run
  /// resumes instead of starting over.
  final Duration recheckAfter;
}

/// One refresh: catalog, stream checks, guide, logos. Each step logs and
/// carries on if another fails; the summary lands in the meta table.
class Refresh {
  Refresh(this.db, this.settings, this.throttle, {void Function(String)? log}) : log = log ?? print;

  final IptvDatabase db;
  final Settings settings;
  final Throttle throttle;
  final void Function(String) log;
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 5)
    ..userAgent = userAgent;

  Future<bool> run([RefreshOptions options = const RefreshOptions()]) async {
    final started = DateTime.now();
    db.setMeta('last_run_started', started.toUtc().toIso8601String());
    final errors = <String>[];
    Future<void> step(String name, bool enabled, Future<void> Function() body) async {
      if (!enabled) return;
      final clock = Stopwatch()..start();
      try {
        await body();
        log('$name: done in ${clock.elapsed.inSeconds} s');
      } catch (e) {
        errors.add('$name: $e');
        log('$name: failed: $e');
      }
    }

    await step('catalog', options.catalog, _catalog);
    await step('check', options.check, () => _checkStreams(options.recheckAfter));
    await step('guide', options.guide, _guide);
    await step('logos', options.logos, _logos);
    client.close(force: true);

    final counts = db.counts();
    db.setMeta('last_run_finished', DateTime.now().toUtc().toIso8601String());
    db.setMeta('last_run_counts', jsonEncode(counts));
    db.setMeta('last_run_errors', jsonEncode(errors));
    log(
      'finished in ${DateTime.now().difference(started).inSeconds} s: $counts${errors.isEmpty ? '' : ', errors: $errors'}',
    );
    return errors.isEmpty;
  }

  Future<List<Map<String, dynamic>>> _api(String name) async {
    final file = await downloadCached(client, Uri.parse('$apiBase/$name.json'), File('${Paths.cache}/api/$name.json'));
    return readJsonList(file);
  }

  Future<void> _catalog() async {
    final catalog = Catalog(
      channels: (await _api('channels')).map(ApiChannel.fromJson).toList(),
      feeds: (await _api('feeds')).map(ApiFeed.fromJson).toList(),
      streams: (await _api('streams')).map(ApiStream.fromJson).toList(),
      logos: (await _api('logos')).map(ApiLogo.fromJson).toList(),
      blocklist: (await _api('blocklist')).map(ApiBlock.fromJson).toList(),
    );
    final selected = select(catalog, settings);
    db.replaceChannels(selected);
    log('catalog: ${selected.length} channels, ${selected.fold<int>(0, (n, c) => n + c.streams.length)} streams');
  }

  Future<void> _checkStreams(Duration recheckAfter) async {
    final checker = StreamChecker(client);
    final streams = db.streamsToCheck(since: DateTime.now().subtract(recheckAfter));
    var working = 0;
    await throttle.forEach(streams, (stream) async {
      final health = await checker.check(stream.url, stream.headers);
      db.recordHealth(stream.id, health, DateTime.now());
      if (health.working) working++;
    });
    log('check: $working of ${streams.length} streams working');
  }

  Future<void> _guide() async {
    final now = DateTime.now().toUtc();
    final wanted = db.guideIds('pluto');
    if (wanted.isEmpty) return;
    final programmes = <Programme>[];
    for (final country in settings.countries.isEmpty ? const ['us'] : settings.countries) {
      final file = File('${Paths.cache}/guides/pluto-${country.toLowerCase()}.xml.gz');
      try {
        await throttle.run(() => downloadCached(client, plutoGuideUrl(country), file));
      } on HttpException catch (e) {
        log('guide: no Pluto guide for $country ($e)');
        continue;
      }
      programmes.addAll(
        await parseXmltv(
          readGzippedXml(file),
          wanted,
          from: now.subtract(const Duration(hours: 3)),
          until: now.add(const Duration(hours: 48)),
        ),
      );
    }
    db.replaceProgrammes(wanted.values.expand((ids) => ids), programmes);
    db.dropOldProgrammes(now.subtract(const Duration(hours: 3)));
    log('guide: ${programmes.length} programmes for ${wanted.length} Pluto channels');
  }

  Future<void> _logos() async {
    final todo = db.logosToFetch();
    final dir = Directory('${Paths.cache}/logos')..createSync(recursive: true);
    var fetched = 0;
    await throttle.forEach(todo.entries, (entry) async {
      final url = Uri.tryParse(entry.value);
      if (url == null) return;
      final ext = p.extension(url.path).toLowerCase();
      final file = File(
        p.join(
          dir.path,
          '${entry.key}${const {'.png', '.jpg', '.jpeg', '.webp', '.gif'}.contains(ext) ? ext : '.img'}',
        ),
      );
      try {
        final r = await fetchHead(client, url, maxBytes: 2 * 1024 * 1024, timeout: const Duration(seconds: 20));
        if (r.status != HttpStatus.ok || r.body.isEmpty) return;
        await file.writeAsBytes(r.body);
        db.setLogoPath(entry.key, file.path);
        fetched++;
      } catch (_) {
        // A missing logo only means initials in the guide.
      }
    });
    log('logos: $fetched of ${todo.length} downloaded');
  }
}
