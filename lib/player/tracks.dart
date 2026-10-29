/// Choosing the version, soundtrack and subtitles to play, from what Jellyfin knows about a file.
///
/// Used on Apple TV, where the server builds the stream: Ember always names the soundtrack it
/// wants, so the server (or Apple's player) never falls back to the file's first track or to the
/// Apple TV's own language. Tested in `test/tracks_test.dart`.
library;

import '../api/jellyfin.dart';
import '../state/app_state.dart';

/// Languages with two three-letter codes (files use either; Settings stores the first), and the
/// two-letter codes some files carry instead.
const _sameLanguage = {
  'ger': 'deu',
  'fre': 'fra',
  'dut': 'nld',
  'chi': 'zho',
  'cze': 'ces',
  'gre': 'ell',
  'per': 'fas',
  'rum': 'ron',
  'slo': 'slk',
  'alb': 'sqi',
  'arm': 'hye',
  'baq': 'eus',
  'bur': 'mya',
  'geo': 'kat',
  'ice': 'isl',
  'mac': 'mkd',
  'mao': 'mri',
  'may': 'msa',
  'tib': 'bod',
  'wel': 'cym',
  'en': 'eng',
  'fr': 'fra',
  'de': 'deu',
  'es': 'spa',
  'it': 'ita',
  'pt': 'por',
  'nl': 'nld',
  'ja': 'jpn',
  'ko': 'kor',
  'zh': 'zho',
  'ru': 'rus',
  'hi': 'hin',
  'ar': 'ara',
  'af': 'afr',
  'zu': 'zul',
  'xh': 'xho',
};

/// Words in a track's title that name its language, for files whose tracks carry no language
/// code (or "und").
const _languageWords = {
  'eng': ['english'],
  'fra': ['french', 'français', 'francais', 'québécois', 'quebecois'],
  'deu': ['german', 'deutsch'],
  'spa': ['spanish', 'español', 'espanol', 'castellano', 'latino'],
  'ita': ['italian', 'italiano'],
  'por': ['portuguese', 'português', 'portugues'],
  'nld': ['dutch', 'nederlands', 'vlaams', 'flemish'],
  'jpn': ['japanese'],
  'kor': ['korean'],
  'zho': ['chinese', 'mandarin', 'cantonese'],
  'rus': ['russian'],
  'hin': ['hindi'],
  'ara': ['arabic'],
  'afr': ['afrikaans'],
  'zul': ['zulu', 'isizulu'],
  'xho': ['xhosa', 'isixhosa'],
};

String? _canonical(String? code) {
  if (code == null) return null;
  final c = code.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (c.length < 2 || c == 'und' || c == 'unk' || c == 'mis' || c == 'zxx' || c == 'mul') return null;
  return _sameLanguage[c] ?? c;
}

/// True when two language codes mean the same language ('fre' and 'fra', 'en' and 'eng').
bool langMatch(String? a, String? b) {
  final x = _canonical(a), y = _canonical(b);
  return x != null && y != null && x == y;
}

String _describe(Map<String, dynamic> s) => '${s['Profile'] ?? ''} ${s['DisplayTitle'] ?? ''} ${s['Title'] ?? ''}'.toLowerCase();

/// The language of a stream: its code, or failing that a language named in its title.
String? trackLanguage(Map<String, dynamic> s) {
  final code = _canonical(s['Language'] as String?);
  if (code != null) return code;
  final words = _describe(s);
  for (final e in _languageWords.entries) {
    if (e.value.any((w) => RegExp('(^|[^a-zà-ÿ])${RegExp.escape(w)}([^a-zà-ÿ]|\$)').hasMatch(words))) return e.key;
  }
  return null;
}

bool _isAtmos(Map<String, dynamic> s) => _describe(s).contains('atmos');
bool _isCommentary(Map<String, dynamic> s) => _describe(s).contains('comment');

/// How well Apple TV plays a soundtrack as it is: Dolby Digital Plus with Atmos is passed
/// straight to the TV or receiver; TrueHD and DTS have to be converted by the server.
int _audioScore(Map<String, dynamic> s) {
  final codec = (s['Codec'] as String? ?? '').toLowerCase();
  final ch = (s['Channels'] as num?)?.toInt() ?? 2;
  var score = ch;
  if (codec == 'eac3' && _isAtmos(s)) score += 100;
  if (codec == 'eac3' || codec == 'ac3' || codec == 'aac' || codec == 'flac' || codec == 'alac') score += 20;
  return score;
}

int? _indexOf(Map<String, dynamic>? s) => (s?['Index'] as num?)?.toInt();

/// The audio and subtitles to ask the server for.
///
/// Audio: the person's preferred language (else the file's default language), and in it the best
/// soundtrack Apple TV plays as it is (Atmos first, never a commentary). Its index is returned
/// whenever the file has more than one soundtrack, so the server sends exactly that one; null
/// means the file has a single soundtrack (or none) and can play untouched.
///
/// Subtitles follow Settings › Subtitles ('off', 'foreign', 'always'): null means none.
/// Subtitles are in [subtitleLanguage] when given (the last language picked in the player),
/// otherwise in the preferred audio language, otherwise English.
(int?, int?) chooseTracks(List<Map<String, dynamic>> streams, String? preferredLanguage, String subtitleMode, {String? subtitleLanguage}) {
  final audio = streams.where((s) => s['Type'] == 'Audio').toList();
  if (audio.isEmpty) return (null, null);
  final defaultAudio = audio.firstWhere((s) => s['IsDefault'] == true, orElse: () => audio.first);
  var lang = trackLanguage(defaultAudio);
  if (preferredLanguage != null && audio.any((s) => langMatch(trackLanguage(s), preferredLanguage))) {
    lang = _canonical(preferredLanguage);
  }
  // Tracks in that language; when the language isn't known, the other tracks of unknown language.
  final sameLang = audio.where((s) => lang == null ? trackLanguage(s) == null : langMatch(trackLanguage(s), lang)).toList();
  final candidates = sameLang.where((s) => !_isCommentary(s)).toList();
  final pool = candidates.isNotEmpty ? candidates : sameLang;
  var chosen = pool.contains(defaultAudio) ? defaultAudio : pool.first;
  for (final s in pool) {
    if (_audioScore(s) > _audioScore(chosen)) chosen = s;
  }

  final subLang = subtitleLanguage ?? preferredLanguage ?? 'eng';
  final chosenLang = trackLanguage(chosen);
  final wantSubs = switch (subtitleMode) {
    'off' => false,
    'always' => true,
    _ => chosenLang != null && !langMatch(chosenLang, preferredLanguage ?? subLang),
  };
  final subs = wantSubs
      ? streams.where((s) => s['Type'] == 'Subtitle' && langMatch(trackLanguage(s), subLang) && s['IsForced'] != true).toList()
      : const <Map<String, dynamic>>[];

  return (audio.length > 1 ? _indexOf(chosen) : null, subs.isEmpty ? null : _indexOf(subs.first));
}

/// When a title has several versions (say an English and a French file), the first one that has
/// a soundtrack in [preferredLanguage]; otherwise the server's first. Returns its MediaSource id.
String? pickMediaSource(List<Map<String, dynamic>> sources, String? preferredLanguage) {
  if (sources.isEmpty) return null;
  if (preferredLanguage != null) {
    for (final src in sources) {
      final streams = (src['MediaStreams'] as List? ?? const []).map((e) => (e as Map).cast<String, dynamic>());
      if (streams.any((s) => s['Type'] == 'Audio' && langMatch(trackLanguage(s), preferredLanguage))) {
        return src['Id'] as String?;
      }
    }
  }
  return sources.first['Id'] as String?;
}

/// The streams of the version with id [mediaSourceId] (or the first version).
List<Map<String, dynamic>> streamsOf(List<Map<String, dynamic>> sources, String? mediaSourceId) {
  if (sources.isEmpty) return const [];
  final src = sources.firstWhere((s) => s['Id'] == mediaSourceId, orElse: () => sources.first);
  return (src['MediaStreams'] as List? ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
}

/// What to ask the server for when a title starts on Apple TV.
class PlaybackPlan {
  final String? mediaSourceId;
  final int? audioIndex;
  final int? subtitleIndex;
  final int? maxBitrate;
  final List<Map<String, dynamic>> streams;
  const PlaybackPlan({this.mediaSourceId, this.audioIndex, this.subtitleIndex, this.maxBitrate, this.streams = const []});
}

/// Picks the version, soundtrack, subtitles and bitrate for [item] before anything is asked of
/// the server, so it is asked only once (instead of once for the default and again for the
/// person's language). The connection test runs at the same time and is remembered.
Future<PlaybackPlan> planPlayback(AppState app, JfItem item, {String? qualityKey}) async {
  final jf = app.jf!;
  final key = qualityKey ?? app.quality;
  if (key == 'auto') jf.connectionSpeed().ignore();
  var sources = item.mediaSources;
  if (sources.isEmpty) {
    try {
      sources = (await jf.item(item.id)).mediaSources;
    } catch (_) {}
  }
  final msid = pickMediaSource(sources, app.preferredAudioLanguage);
  final streams = streamsOf(sources, msid);
  final (audio, sub) = chooseTracks(streams, app.preferredAudioLanguage, app.subtitleMode, subtitleLanguage: app.preferredSubtitleLanguage);
  final src = sources.where((s) => s['Id'] == msid).firstOrNull;
  final bitrate = await app.maxBitrateFor((src?['Bitrate'] as num?)?.toInt(), qualityKey: key);
  return PlaybackPlan(mediaSourceId: msid, audioIndex: audio, subtitleIndex: sub, maxBitrate: bitrate, streams: streams);
}

/// The code Settings › Preferred audio language uses for [lang] ('fre' rather than 'fra').
String preferredCode(String lang) {
  final c = _canonical(lang) ?? lang;
  for (final e in _sameLanguage.entries) {
    if (e.value == c && e.key.length == 3) return e.key;
  }
  return c;
}

/// Language names for the player's Audio & Subtitles menu, by the codes [trackLanguage] returns.
const _languageNames = {
  'eng': 'English',
  'fra': 'French',
  'deu': 'German',
  'spa': 'Spanish',
  'ita': 'Italian',
  'por': 'Portuguese',
  'nld': 'Dutch',
  'jpn': 'Japanese',
  'kor': 'Korean',
  'zho': 'Chinese',
  'rus': 'Russian',
  'hin': 'Hindi',
  'ara': 'Arabic',
  'afr': 'Afrikaans',
  'zul': 'Zulu',
  'xho': 'Xhosa',
  'swe': 'Swedish',
  'nor': 'Norwegian',
  'nob': 'Norwegian',
  'dan': 'Danish',
  'fin': 'Finnish',
  'pol': 'Polish',
  'tur': 'Turkish',
  'ces': 'Czech',
  'ell': 'Greek',
  'heb': 'Hebrew',
  'hun': 'Hungarian',
  'ron': 'Romanian',
  'tha': 'Thai',
  'vie': 'Vietnamese',
  'ind': 'Indonesian',
  'msa': 'Malay',
  'ukr': 'Ukrainian',
  'tam': 'Tamil',
  'tel': 'Telugu',
  'fil': 'Filipino',
  'tgl': 'Filipino',
  'cat': 'Catalan',
  'hrv': 'Croatian',
  'srp': 'Serbian',
  'bul': 'Bulgarian',
  'slk': 'Slovak',
  'fas': 'Persian',
  'isl': 'Icelandic',
  'est': 'Estonian',
  'lav': 'Latvian',
  'lit': 'Lithuanian',
  'slv': 'Slovenian',
  'ben': 'Bengali',
  'urd': 'Urdu',
  'swa': 'Swahili',
  'sot': 'Sesotho',
  'tsn': 'Setswana',
  'nso': 'Sepedi',
};

/// "English", "French"… for a language code in any spelling; null when it isn't known.
String? languageName(String? code) {
  final c = _canonical(code);
  return c == null ? null : (_languageNames[c] ?? c.toUpperCase());
}

/// How a soundtrack reads in the player's menu: "English 5.1", "French", "English – Audio
/// Description", "English – Commentary".
String audioLabel(Map<String, dynamic> s) {
  final d = _describe(s);
  final name = languageName(trackLanguage(s)) ?? _fallbackName(s, 'Audio');
  final ch = (s['Channels'] as num?)?.toInt() ?? 2;
  final parts = <String>[name];
  if (ch > 2) parts.add('${ch - 1}.1');
  if (_isAtmos(s)) parts.add('Atmos');
  var label = parts.join(' ');
  if (d.contains('descri')) {
    label += ' – Audio Description';
  } else if (_isCommentary(s)) {
    label += ' – Commentary';
  }
  return label;
}

/// How a subtitle track reads in the player's menu: "English", "English (CC)", "French (Forced)".
String subtitleLabel(Map<String, dynamic> s) {
  final d = _describe(s);
  var label = languageName(trackLanguage(s)) ?? _fallbackName(s, 'Subtitles');
  if (s['IsHearingImpaired'] == true || RegExp(r'\b(sdh|cc)\b').hasMatch(d) || d.contains('hearing')) {
    label += ' (CC)';
  } else if (s['IsForced'] == true || d.contains('forced')) {
    label += ' (Forced)';
  }
  return label;
}

String _fallbackName(Map<String, dynamic> s, String kind) {
  final t = (s['Title'] as String?)?.trim();
  if (t != null && t.isNotEmpty) return t;
  final dt = (s['DisplayTitle'] as String?)?.trim();
  if (dt != null && dt.isNotEmpty) return dt;
  return '$kind ${s['Index'] ?? ''}'.trim();
}

/// [labels] with repeats told apart ("English 5.1 · EAC3", then "· 2", "· 3"…), in order.
List<String> distinctLabels(List<String> labels, List<Map<String, dynamic>> streams) {
  final out = [...labels];
  for (var i = 0; i < out.length; i++) {
    if (labels.where((l) => l == labels[i]).length < 2) continue;
    final codec = (streams[i]['Codec'] as String?)?.toUpperCase();
    if (codec != null && codec.isNotEmpty) out[i] = '${labels[i]} · $codec';
  }
  for (var i = 0; i < out.length; i++) {
    final same = [
      for (var j = 0; j < out.length; j++)
        if (out[j] == out[i]) j,
    ];
    if (same.length > 1) {
      for (var k = 1; k < same.length; k++) {
        out[same[k]] = '${out[same[k]]} · ${k + 1}';
      }
    }
  }
  return out;
}

/// The Subtitles setting after the person turns subtitles [on] or off in the player, the way a
/// streaming app remembers it: subtitles over a soundtrack in their own language mean "always";
/// turning them off over a foreign soundtrack means "off". Otherwise the setting stays.
String rememberedSubtitleMode(String current, {required bool on, required bool ownLanguageAudio}) {
  if (on) {
    if (ownLanguageAudio) return 'always';
    return current == 'off' ? 'foreign' : current;
  }
  if (ownLanguageAudio) return current == 'always' ? 'foreign' : current;
  return 'off';
}
