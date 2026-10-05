/// iptv-org API records (https://iptv-org.github.io/api/), only the fields
/// couchbox-iptv uses.
library;

List<String> _strings(Object? value) => (value as List? ?? const []).cast<String>();

class ApiChannel {
  ApiChannel.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['name'] as String,
      country = json['country'] as String?,
      categories = _strings(json['categories']),
      isNsfw = json['is_nsfw'] as bool? ?? false,
      closed = json['closed'] as String?,
      replacedBy = json['replaced_by'] as String?;

  /// A channel iptv-org has no record for, made from a guide's listing.
  ApiChannel.synthetic({required this.id, required this.name, this.country})
    : categories = const [],
      isNsfw = false,
      closed = null,
      replacedBy = null;

  final String id;
  final String name;
  final String? country;
  final List<String> categories;
  final bool isNsfw;
  final String? closed;
  final String? replacedBy;
}

class ApiFeed {
  ApiFeed.fromJson(Map<String, dynamic> json)
    : channel = json['channel'] as String,
      id = json['id'] as String,
      isMain = json['is_main'] as bool? ?? false,
      languages = _strings(json['languages']);

  final String channel;
  final String id;
  final bool isMain;

  /// ISO 639-3 codes, e.g. "eng".
  final List<String> languages;
}

class ApiStream {
  ApiStream.fromJson(Map<String, dynamic> json)
    : channel = json['channel'] as String?,
      feed = json['feed'] as String?,
      title = json['title'] as String?,
      url = json['url'] as String,
      quality = json['quality'] as String?,
      labels = _strings(json['labels']),
      userAgent = json['user_agent'] as String?,
      referrer = json['referrer'] as String?;

  final String? channel;
  final String? feed;
  final String? title;
  final String url;

  /// "1080p", "720p", ... or null.
  final String? quality;

  /// "Geo-blocked", "Not 24/7".
  final List<String> labels;
  final String? userAgent;
  final String? referrer;

  /// Vertical resolution from [quality], 0 when unknown.
  int get lines => int.tryParse(RegExp(r'^(\d+)').firstMatch(quality ?? '')?.group(1) ?? '') ?? 0;
}

class ApiLogo {
  /// A logo from a guide's listing.
  ApiLogo.synthetic(this.channel, this.url) : feed = null, inUse = true, width = 0, format = null;

  ApiLogo.fromJson(Map<String, dynamic> json)
    : channel = json['channel'] as String,
      feed = json['feed'] as String?,
      inUse = json['in_use'] as bool? ?? false,
      width = (json['width'] as num?)?.toInt() ?? 0,
      format = json['format'] as String?,
      url = json['url'] as String;

  final String channel;
  final String? feed;
  final bool inUse;
  final int width;
  final String? format;
  final String url;
}

class ApiBlock {
  ApiBlock.fromJson(Map<String, dynamic> json) : channel = json['channel'] as String;

  final String channel;
}
