import 'package:ember/util/log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tokens, cookies and keys never reach the log', () {
    expect(
      redact('Failed to open http://h/Videos/1/stream?static=true&api_key=abc123&x=1'),
      'Failed to open http://h/Videos/1/stream?static=true&api_key=…&x=1',
    );
    expect(redact('MediaBrowser Client="Ember", Token="t0k"'), 'MediaBrowser Client="Ember", Token="…"');
    expect(redact('cookie connect.sid=s%3Aabc.def; Path=/'), 'cookie connect.sid=…; Path=/');
    expect(redact('X-Api-Key: k3y'), 'X-Api-Key: …');
    expect(redact('Server returned 500 for /Items'), 'Server returned 500 for /Items');
  });
}
