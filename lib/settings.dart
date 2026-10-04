import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// What the viewer picked, in ~/.config/couchbox-iptv/settings.json. Shared by
/// the app (which writes it) and the refresh job (which reads it).
class Settings {
  const Settings({
    this.countries = const ['US'],
    this.languages = const ['eng'],
    this.categories = const [],
    this.audioLanguages = const ['eng'],
    this.subtitleLanguages = const [],
    this.hideDead = true,
    this.preview = true,
  });

  factory Settings.fromJson(Map<String, dynamic> json) {
    List<String> list(String key, List<String> fallback) =>
        json[key] is List ? (json[key] as List).cast<String>() : fallback;
    const d = Settings();
    return Settings(
      countries: list('countries', d.countries),
      languages: list('languages', d.languages),
      categories: list('categories', d.categories),
      audioLanguages: list('audio_languages', d.audioLanguages),
      subtitleLanguages: list('subtitle_languages', d.subtitleLanguages),
      hideDead: json['hide_dead'] as bool? ?? d.hideDead,
      preview: json['preview'] as bool? ?? d.preview,
    );
  }

  /// ISO 3166-1 alpha-2 country codes ("US"). Empty: every country.
  final List<String> countries;

  /// ISO 639-3 language codes ("eng"). Empty: every language.
  final List<String> languages;

  /// iptv-org category ids ("news"). Empty: every category.
  final List<String> categories;

  /// Preferred audio and subtitle languages, in order (mpv alang, slang).
  final List<String> audioLanguages;
  final List<String> subtitleLanguages;

  /// Leave streams that failed their last check out of the guide.
  final bool hideDead;

  /// Play the focused channel in a box above the guide.
  final bool preview;

  Map<String, Object?> toJson() => {
    'countries': countries,
    'languages': languages,
    'categories': categories,
    'audio_languages': audioLanguages,
    'subtitle_languages': subtitleLanguages,
    'hide_dead': hideDead,
    'preview': preview,
  };

  static File get file => File('${Paths.config}/settings.json');

  /// The saved settings, or the defaults when there are none or the file is
  /// unreadable.
  static Settings load() {
    try {
      return Settings.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      return const Settings();
    }
  }

  void save() {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp')..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
    tmp.renameSync(file.path);
  }
}
