/// The ISO 639-1 and 639-2/B codes that go with common ISO 639-3 codes.
/// Streams tag their tracks with any of the three ("en", "eng"), and mpv's
/// alang/slang match the tag literally.
const _aliases = <String, List<String>>{
  'ara': ['ar'],
  'ben': ['bn'],
  'deu': ['de', 'ger'],
  'ell': ['el', 'gre'],
  'eng': ['en'],
  'fas': ['fa', 'per'],
  'fra': ['fr', 'fre'],
  'heb': ['he'],
  'hin': ['hi'],
  'hye': ['hy', 'arm'],
  'ita': ['it'],
  'jpn': ['ja'],
  'kor': ['ko'],
  'nld': ['nl', 'dut'],
  'pol': ['pl'],
  'por': ['pt'],
  'ron': ['ro', 'rum'],
  'rus': ['ru'],
  'spa': ['es'],
  'swe': ['sv'],
  'tur': ['tr'],
  'ukr': ['uk'],
  'vie': ['vi'],
  'zho': ['zh', 'chi'],
};

/// mpv's alang/slang value for [languages] (ISO 639-3, in order of
/// preference): each code followed by its other spellings.
String mpvLanguageList(List<String> languages) => [
  for (final code in languages) ...[code, ...?_aliases[code]],
].join(',');
