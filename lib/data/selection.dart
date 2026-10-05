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
      final id = plutoIdOf(s.url);
      if (id != null) return id;
    }
    return null;
  }
}

final _plutoUrl = RegExp(r'^https?://jmp2\.uk/plu-([0-9a-f]{24})\b');

/// The Pluto TV channel id in a `jmp2.uk/plu-<id>` link, else null.
String? plutoIdOf(String url) => _plutoUrl.firstMatch(url)?.group(1);

/// A channel in a Pluto TV guide (i.mjh.nz), for streams iptv-org lists
/// without a channel record.
class PlutoListing {
  const PlutoListing({required this.name, this.logo, required this.country});

  final String name;
  final String? logo;

  /// The guide it came from ("US").
  final String country;
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
///
/// iptv-org also lists streams with no channel record (about a tenth of
/// them, many Pluto TV). A Pluto one whose channel is in [pluto] (the guide
/// for the selected countries) becomes a channel of its own, `pluto.<id>`,
/// named as in the guide; channel-less streams with the same title are added
/// to it as further streams. Other channel-less streams are left out: with
/// no country or language they would slip past the filters.
List<SelectedChannel> select(Catalog catalog, Settings settings, {Map<String, PlutoListing> pluto = const {}}) {
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
  if (categories.isEmpty) selected.addAll(_plutoOnly(catalog, pluto, countries));
  selected.sort((a, b) => a.channel.name.toLowerCase().compareTo(b.channel.name.toLowerCase()));
  return selected;
}

/// Channels for channel-less Pluto streams; see [select]. Never matched by a
/// category filter (iptv-org gives them no categories).
List<SelectedChannel> _plutoOnly(Catalog catalog, Map<String, PlutoListing> pluto, Set<String> countries) {
  // Pluto channels some iptv-org channel already carries.
  final known = <String>{
    for (final s in catalog.streams)
      if (s.channel != null) ?plutoIdOf(s.url),
  };
  final loose = [
    for (final s in catalog.streams)
      if (s.channel == null) s,
  ];
  final byTitle = <String, List<ApiStream>>{};
  for (final s in loose) {
    final title = s.title?.trim().toLowerCase();
    if (title != null && title.isNotEmpty) (byTitle[title] ??= []).add(s);
  }
  final out = <SelectedChannel>[];
  final done = <String>{};
  for (final s in loose) {
    final id = plutoIdOf(s.url);
    final listing = id == null ? null : pluto[id];
    if (listing == null || known.contains(id) || !done.add(id!)) continue;
    if (countries.isNotEmpty && !countries.contains(listing.country)) continue;
    final channelId = 'pluto.$id';
    // The Pluto stream, then others with the same title (Roku, Tubi, ...).
    final others = (byTitle[listing.name.trim().toLowerCase()] ?? const <ApiStream>[]).where(
      (o) => o.url != s.url && plutoIdOf(o.url) == null,
    );
    out.add(
      SelectedChannel(ApiChannel.synthetic(id: channelId, name: listing.name, country: listing.country), const [], [
        s,
        ...rankStreams(others.toList()),
      ], listing.logo == null ? null : ApiLogo.synthetic(channelId, listing.logo!)),
    );
  }
  return out;
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
