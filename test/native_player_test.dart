import 'package:ember/player/native_player.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> audio(int i, String lang, String codec, {int ch = 6, String title = '', bool def = false}) => {
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
    final (a, s, reopen) = NativePlayer.chooseTracks(streams, null, 'foreign');
    expect(a, 2);
    expect(s, isNull);
    expect(reopen, isTrue);
  });

  test('keeps the default when it is already the best track, so the original file plays untouched', () {
    final streams = [
      audio(1, 'eng', 'eac3', title: 'English Atmos', def: true),
      audio(2, 'eng', 'aac', ch: 2, title: 'English Stereo'),
    ];
    expect(NativePlayer.chooseTracks(streams, 'eng', 'foreign'), (null, null, false));
  });

  test('never switches to a commentary track', () {
    final streams = [
      audio(1, 'eng', 'ac3', ch: 6, title: 'English 5.1', def: true),
      audio(2, 'eng', 'eac3', ch: 6, title: 'Director\'s commentary Atmos'),
    ];
    expect(NativePlayer.chooseTracks(streams, null, 'off').$1, isNull);
  });

  test('foreign-language audio turns on subtitles in the person\'s language, skipping forced ones', () {
    final streams = [audio(1, 'jpn', 'eac3', def: true), sub(5, 'eng', forced: true), sub(6, 'eng'), sub(7, 'spa')];
    expect(NativePlayer.chooseTracks(streams, 'eng', 'foreign'), (null, 6, true));
    expect(NativePlayer.chooseTracks(streams, 'eng', 'off'), (null, null, false));
  });

  test('preferred language wins over the file\'s default', () {
    final streams = [audio(1, 'eng', 'eac3', def: true), audio(2, 'deu', 'ac3'), sub(3, 'deu')];
    expect(NativePlayer.chooseTracks(streams, 'ger', 'always'), (2, 3, true));
  });
}
