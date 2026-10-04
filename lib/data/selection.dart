import '../settings.dart';
import 'models.dart';

/// A channel the viewer gets, with its streams best first.
class SelectedChannel {
  SelectedChannel(this.channel, this.languages, this.streams, this.logo);

  final ApiChannel channel;

  /// From the feeds its streams carry; empty when iptv-org doesn't say.
  final List<String> languages;
  final List<ApiStream> streams;
  final ApiLogo? logo;

  /// Pluto TV's channel id, when a stream goes through i.mjh.nz's
  /// `jmp2.uk/plu-<id>` links; the key into i.mjh.nz's Pluto guide.
  String? get plutoId {
    for (final s in streams) {
      final m = _plutoUrl.firstMatch(s.url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  static final _plutoUrl = RegExp(r'^https?://jmp2\.uk/plu-([0-9a-f]{24})\b');
}

/// The iptv-org data, as downloaded.
class Catalog {
  Catalog({
    required this.channels,
    required this.feeds,
    required this.streams,
    required this.logos,
    required this.blocklist,
  });

  final List<ApiChannel> channels;
  final List<ApiFeed> feeds;
  final List<ApiStream> streams;
  final List<ApiLogo> logos;
  final List<ApiBlock> blocklist;
}

/// The channels [settings] asks for. NSFW, blocklisted and closed channels,
/// and channels with no stream, are always left out. A channel whose language
/// iptv-org doesn't record passes the language filter.
List<SelectedChannel> select(Catalog catalog, Settings settings) {
  final blocked = {for (final b in catalog.blocklist) b.channel};
  final feeds = <String, Map<String, ApiFeed>>{};
  for (final f in catalog.feeds) {
    (feeds[f.channel] ??= {})[f.id] = f;
  }
  final streams = <String, List<ApiStream>>{};
  for (final s in catalog.streams) {
    if (s.channel != null) (streams[s.channel!] ??= []).add(s);
  }
  final logos = <String, List<ApiLogo>>{};
  for (final l in catalog.logos) {
    (logos[l.channel] ??= []).add(l);
  }

  final countries = settings.countries.toSet();
  final languages = settings.languages.toSet();
  final categories = settings.categories.toSet();
  final selected = <SelectedChannel>[];
  for (final c in catalog.channels) {
    if (c.isNsfw || blocked.contains(c.id) || c.closed != null || c.replacedBy != null) continue;
    final channelStreams = streams[c.id];
    if (channelStreams == null || channelStreams.isEmpty) continue;
    if (countries.isNotEmpty && !countries.contains(c.country)) continue;
    if (categories.isNotEmpty && !c.categories.any(categories.contains)) continue;

    final channelFeeds = feeds[c.id] ?? const {};
    final mainFeed = channelFeeds.values.where((f) => f.isMain).firstOrNull;
    final langs = <String>{};
    for (final s in channelStreams) {
      final feed = s.feed == null ? mainFeed : channelFeeds[s.feed];
      langs.addAll(feed?.languages ?? const []);
    }
    if (languages.isNotEmpty && langs.isNotEmpty && !langs.any(languages.contains)) continue;

    selected.add(SelectedChannel(c, langs.toList()..sort(), rankStreams(channelStreams), bestLogo(logos[c.id])));
  }
  selected.sort((a, b) => a.channel.name.toLowerCase().compareTo(b.channel.name.toLowerCase()));
  return selected;
}

/// Best first: streams that are neither geo-blocked nor part-time, then by
/// resolution (up to 1080 lines; more costs bandwidth for little on a 1080p
/// TV), then in iptv-org's order.
List<ApiStream> rankStreams(List<ApiStream> streams) {
  int penalty(ApiStream s) => (s.labels.contains('Geo-blocked') ? 2 : 0) + (s.labels.contains('Not 24/7') ? 1 : 0);
  int lines(ApiStream s) => s.lines > 1080 ? 1080 : s.lines;
  final indexed = streams.indexed.toList()
    ..sort((a, b) {
      final p = penalty(a.$2).compareTo(penalty(b.$2));
      if (p != 0) return p;
      final l = lines(b.$2).compareTo(lines(a.$2));
      return l != 0 ? l : a.$1.compareTo(b.$1);
    });
  return [for (final (_, s) in indexed) s];
}

/// A logo Flutter can draw (PNG or JPEG, not SVG), preferring one in use for
/// the whole channel and close to 256 px wide.
ApiLogo? bestLogo(List<ApiLogo>? logos) {
  final usable = (logos ?? const <ApiLogo>[])
      .where((l) => l.format == null || const {'PNG', 'JPEG', 'WebP', 'GIF'}.contains(l.format))
      .toList();
  if (usable.isEmpty) return null;
  int score(ApiLogo l) =>
      (l.inUse ? 0 : 10000) + (l.feed == null ? 0 : 5000) + (l.width == 0 ? 1000 : (l.width - 256).abs());
  usable.sort((a, b) => score(a).compareTo(score(b)));
  return usable.first;
}
