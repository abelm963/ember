// Checks that Ember can find trailer streams on its own: `dart run tool/trailer_probe.dart <youtube ids>`.
// Prints which way each trailer was found, then every other way in turn, and how long each took.
// ignore_for_file: avoid_print
import 'package:ember/api/youtube.dart';

Future<void> main(List<String> ids) async {
  var ok = 0;
  for (final id in ids) {
    final tried = <TrailerSource>{};
    final sw = Stopwatch()..start();
    var s = await YouTubeTrailers.resolve(id);
    if (s != null) ok++;
    final found = <String>[];
    while (s != null) {
      found.add('$s (${sw.elapsedMilliseconds}ms)');
      sw.reset();
      s = await YouTubeTrailers.nextAfter(s, tried);
    }
    print('$id  ${found.isEmpty ? 'nothing found' : found.join('  then  ')}');
  }
  print('$ok of ${ids.length} trailers playable');
}
