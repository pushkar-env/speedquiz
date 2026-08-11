/// Maps `speedquiz://results/{id}` (and path variants) to in-app routes.
String? locationFromDeepLink(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

  // speedquiz://results/{sessionId}
  if (scheme == 'speedquiz' && host == 'results' && segments.isNotEmpty) {
    return '/share/results/${segments.first}';
  }

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
