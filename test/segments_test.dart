import 'package:ember/api/jellyfin.dart';
import 'package:ember/player/segments.dart';
import 'package:flutter_test/flutter_test.dart';

MediaSegment seg(String type, int from, int to) => MediaSegment(type, Duration(seconds: from), Duration(seconds: to));
List<String> show(List<MediaSegment> s) => [for (final x in s) '${x.type} ${x.start.inSeconds}-${x.end.inSeconds}'];
const ep = Duration(minutes: 45);

void main() {
  test('good times from the server are kept, in order', () {
    expect(show(tidySegments([seg('Outro', 2580, 2700), seg('Intro', 60, 120), seg('Recap', 0, 50)], ep)), [
      'Recap 0-50',
      'Intro 60-120',
      'Outro 2580-2700',
    ]);
  });

  test('credits marked mid-episode are ignored, so Next Episode does not cut a scene short', () {
    expect(show(tidySegments([seg('Outro', 1200, 1300), seg('Outro', 2600, 2700)], ep)), ['Outro 2600-2700']);
  });

  test('an intro that is too long or too late is ignored', () {
    expect(tidySegments([seg('Intro', 30, 600)], ep), isEmpty);
    expect(tidySegments([seg('Intro', 1800, 1860)], ep), isEmpty);
  });

  test('tiny, backwards and overlong times are dropped or trimmed', () {
    expect(tidySegments([seg('Intro', 60, 61), seg('Recap', 50, 10)], ep), isEmpty);
    expect(show(tidySegments([seg('Outro', 2600, 9999)], ep)), ['Outro 2600-2700']);
  });

  test('chapter names fill in what the server lacks', () {
    final chapters = <Chapter>[
      (name: 'Previously On', start: Duration.zero),
      (name: 'Opening', start: const Duration(seconds: 40)),
      (name: 'Chapter 3', start: const Duration(seconds: 100)),
      (name: 'End Credits', start: const Duration(seconds: 2610)),
    ];
    expect(show(tidySegments([], ep, chapters: chapters)), ['Recap 0-40', 'Intro 40-100', 'Outro 2610-2700']);
    // The server's own times win.
    expect(show(tidySegments([seg('Intro', 45, 95)], ep, chapters: chapters)), [
      'Recap 0-40',
      'Intro 45-95',
      'Outro 2610-2700',
    ]);
  });

  test('before the length is known, only basic checks apply', () {
    expect(show(tidySegments([seg('Intro', 60, 120), seg('Outro', 1200, 1300)], Duration.zero)), [
      'Intro 60-120',
      'Outro 1200-1300',
    ]);
  });
}
