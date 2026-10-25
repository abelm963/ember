// Checks that Ember can find trailer streams on its own: `dart run tool/trailer_probe.dart <youtube ids>`.
// Prints which kind of stream was found for each video and whether its address answers.
// ignore_for_file: avoid_print
import 'package:ember/api/youtube.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> ids) async {
  var ok = 0;
  for (final id in ids) {
    final sw = Stopwatch()..start();
    final hls = await YouTubeTrailers.iosHls(id).catchError((_) => null);
    final hlsMs = sw.elapsedMilliseconds;
    var hlsWorks = false;
    if (hls != null) {
      final r = await http.get(Uri.parse(hls)).catchError((_) => http.Response('', 599));
      hlsWorks = r.statusCode == 200 && r.body.startsWith('#EXTM3U');
    }
    sw.reset();
    final s = await YouTubeTrailers.resolve(id);
    final ms = sw.elapsedMilliseconds;
    var answers = false;
    if (s != null) {
      final r = await http.get(Uri.parse(s.url), headers: {'Range': 'bytes=0-1023'}).catchError((_) => http.Response('', 599));
      answers = r.statusCode == 200 || r.statusCode == 206;
    }
    if (answers) ok++;
    print('$id  ios-hls: ${hls == null ? 'none' : (hlsWorks ? 'playlist OK' : 'playlist refused')} (${hlsMs}ms)  '
        'chosen: ${s ?? 'nothing'} (${ms}ms)  stream answers: $answers');
  }
  print('$ok of ${ids.length} trailers playable');
}
