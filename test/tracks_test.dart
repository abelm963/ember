import 'package:ember/player/tracks.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> audio(int i, String? lang, String codec, {int ch = 6, String title = '', bool def = false}) => {
  'Type': 'Audio',
  'Index': i,
  'Language': lang,
  'Codec': codec,
  'Channels': ch,
  'DisplayTitle': title,
  'IsDefault': def,
};
Map<String, dynamic> sub(int i, String lang, {bool forced = false}) => {
  'Type': 'Subtitle',
  'Index': i,
  'Language': lang,
  'IsForced': forced,
};

void main() {
  test('prefers the Dolby Atmos (E-AC-3) track over a TrueHD default in the same language', () {
    final streams = [
      audio(1, 'eng', 'truehd', ch: 8, title: 'English Dolby TrueHD Atmos 7.1', def: true),
      audio(2, 'eng', 'eac3', ch: 6, title: 'English Dolby Digital Plus Atmos 5.1'),
      audio(3, 'fra', 'eac3', ch: 6, title: 'Français Dolby Digital Plus Atmos'),
    ];
    expect(chooseTracks(streams, null, 'foreign'), (2, null));
  });

  test('always names the soundtrack when a file has several, even the default', () {
    final streams = [
      audio(1, 'eng', 'eac3', title: 'English Atmos', def: true),
      audio(2, 'eng', 'aac', ch: 2, title: 'English Stereo'),
    ];
    expect(chooseTracks(streams, 'eng', 'foreign'), (1, null));
  });

  test('a single soundtrack is left alone, so the original file plays untouched', () {
    expect(chooseTracks([audio(1, 'eng', 'eac3', def: true)], 'eng', 'foreign'), (null, null));
  });

  test('never switches to a commentary track', () {
    final streams = [
      audio(1, 'eng', 'ac3', ch: 6, title: 'English 5.1', def: true),
      audio(2, 'eng', 'eac3', ch: 6, title: 'Director\'s commentary Atmos'),
    ];
    expect(chooseTracks(streams, null, 'off').$1, 1);
  });

  test('foreign-language audio turns on subtitles in the person\'s language, skipping forced ones', () {
    final streams = [audio(1, 'jpn', 'eac3', def: true), sub(5, 'eng', forced: true), sub(6, 'eng'), sub(7, 'spa')];
    expect(chooseTracks(streams, 'eng', 'foreign'), (null, 6));
    expect(chooseTracks(streams, 'eng', 'off'), (null, null));
  });

  test('preferred language wins over the file\'s default', () {
    final streams = [audio(1, 'eng', 'eac3', def: true), audio(2, 'deu', 'ac3'), sub(3, 'deu')];
    expect(chooseTracks(streams, 'ger', 'always'), (2, 3));
  });

  test('Frozen: French is the default track, English is preferred, English plays', () {
    final streams = [
      audio(1, 'fre', 'eac3', title: 'Français - Dolby Digital+ - 5.1 - Default', def: true),
      audio(2, 'eng', 'ac3', title: 'English - Dolby Digital - 5.1'),
    ];
    expect(chooseTracks(streams, 'eng', 'foreign'), (2, null));
  });

  test('tracks without a language code are matched by the language in their title', () {
    final streams = [
      audio(1, 'und', 'eac3', title: 'French 5.1', def: true),
      audio(2, null, 'ac3', title: 'English 5.1'),
    ];
    expect(chooseTracks(streams, 'eng', 'foreign').$1, 2);
    expect(trackLanguage(streams[0]), 'fra');
  });

  test('language codes in their different spellings match', () {
    expect(langMatch('fre', 'fra'), isTrue);
    expect(langMatch('fr', 'fre'), isTrue);
    expect(langMatch('en', 'eng'), isTrue);
    expect(langMatch('ger', 'de'), isTrue);
    expect(langMatch('eng', 'fre'), isFalse);
    expect(langMatch('und', 'eng'), isFalse);
    expect(preferredCode('fra'), 'fre');
    expect(preferredCode('en'), 'eng');
  });

  test('with an English and a French version of a film, the English one is picked', () {
    final sources = <Map<String, dynamic>>[
      {'Id': 'fr', 'MediaStreams': [audio(1, 'fra', 'ac3', def: true)]},
      {'Id': 'en', 'MediaStreams': [audio(1, 'eng', 'ac3', def: true)]},
    ];
    expect(pickMediaSource(sources, 'eng'), 'en');
    expect(pickMediaSource(sources, null), 'fr');
    expect(streamsOf(sources, 'en').first['Language'], 'eng');
  });
}
