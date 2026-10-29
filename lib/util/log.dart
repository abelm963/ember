import 'package:flutter/foundation.dart';

/// Writes a line to the device log (the debug console on Windows, Xcode's console for Apple TV)
/// for something that went wrong but that Ember carries on without, so field problems can be
/// traced. Sign-in tokens, session cookies and API keys are removed first ([redact]).
void logWarning(String where, Object error) {
  debugPrint('Ember [$where] ${redact('$error')}');
}

final _secrets = <RegExp>[
  RegExp(r'((?:api_key|ApiKey|apikey|X-Api-Key)[=:]\s*)[^&\s,;"]+', caseSensitive: false),
  RegExp(r'(Token=")[^"]*'),
  RegExp(r'(connect\.sid=)[^;\s]+'),
];

/// [text] with anything that would let someone sign in as this person replaced by `…`.
String redact(String text) {
  var out = text;
  for (final r in _secrets) {
    out = out.replaceAllMapped(r, (m) => '${m[1]}…');
  }
  return out;
}
