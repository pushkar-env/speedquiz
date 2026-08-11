import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/routing/deep_links.dart';

/// Listens for cold-start + runtime deep links and navigates via [router].
class DeepLinkListener extends StatefulWidget {
  const DeepLinkListener({
    super.key,
    required this.router,
    required this.child,
  });

  final GoRouter router;
  final Widget child;

  @override
  State<DeepLinkListener> createState() => _DeepLinkListenerState();
}

class _DeepLinkListenerState extends State<DeepLinkListener> {
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _navigate(Uri uri, {bool afterAuthSettle = false}) {
    final location = locationFromDeepLink(uri);
    if (location == null) return;
    Future<void>(() async {
      // Cold start: splash auth redirect may briefly force /home — wait then open share.
      if (afterAuthSettle) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      if (!mounted) return;
      widget.router.go(location);
    });
  }

  Future<void> _start() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        _navigate(initial, afterAuthSettle: true);
      }
    } catch (e) {
      debugPrint('deep_link_initial_failed: $e');
    }

    _sub = _appLinks.uriLinkStream.listen(
      (uri) => _navigate(uri),
      onError: (Object e) => debugPrint('deep_link_stream_failed: $e'),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
