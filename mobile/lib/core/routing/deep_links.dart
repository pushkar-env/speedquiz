/// Maps `speedquiz://results/{id}` (and path variants) to in-app routes.
String? locationFromDeepLink(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

  // speedquiz://results/{sessionId}
  if (scheme == 'speedquiz' && host == 'results' && segments.isNotEmpty) {
    return '/share/results/${segments.first}';
  }

  // A custom-quiz share code. `speedquiz://quiz/{CODE}`, its path variant, and
  // the short HTTPS form `/q/{CODE}` — the one that fits in a chat message.
  // The code is normalized here so a link carrying it lowercased, or with a
  // trailing separator, still resolves.
  final code = _quizCode(scheme, host, segments);
  if (code != null) return '/studio/code/$code';

  // speedquiz:///results/{sessionId}
  if (scheme == 'speedquiz') {
    if (segments.length >= 2 && segments[0] == 'results') {
      return '/share/results/${segments[1]}';
    }
  }

  // Public landing: /r/{id}
  if (segments.length >= 2 && segments[0] == 'r') {
    return '/share/results/${segments[1]}';
  }

  // HTTPS /share/results/{id} or /results/{id}
  if (segments.length >= 3 &&
      segments[0] == 'share' &&
      segments[1] == 'results') {
    return '/share/results/${segments[2]}';
  }
  if (segments.length >= 2 && segments[0] == 'results') {
    return '/share/results/${segments[1]}';
  }

  return null;
}

/// The six-character share code carried by a quiz link, if this is one.
String? _quizCode(String scheme, String host, List<String> segments) {
  String? raw;
  if (scheme == 'speedquiz' && host == 'quiz' && segments.isNotEmpty) {
    raw = segments.first;
  } else if (segments.length >= 2 && (segments[0] == 'q' || segments[0] == 'quiz')) {
    raw = segments[1];
  } else if (scheme == 'speedquiz' &&
      segments.length >= 2 &&
      segments[0] == 'quiz') {
    raw = segments[1];
  }
  if (raw == null) return null;

  // Mirrors the server's alphabet: no vowels, no 0/O or 1/I. Anything else in
  // the segment is punctuation a messaging app stuck to the end of the link.
  final normalized = raw
      .toUpperCase()
      .split('')
      .where((c) => '23456789BCDFGHJKMNPQRSTVWXYZ'.contains(c))
      .join();
  return normalized.length == 6 ? normalized : null;
}
