import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:quizverse/core/config/app_config.dart';

class GoogleAuthService {
  GoogleAuthService();

  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    if (!AppConfig.hasGoogleSignInConfig) {
      throw StateError(
        'GOOGLE_SERVER_CLIENT_ID is not set. '
        'Rebuild with --dart-define=GOOGLE_SERVER_CLIENT_ID=<Web client ID>.',
      );
    }
    await GoogleSignIn.instance.initialize(
      serverClientId: AppConfig.googleServerClientId,
    );
    _initialized = true;
  }

  /// Returns a Google ID token for backend verification, or null if cancelled.
  Future<String?> obtainIdToken() async {
    await _ensureInitialized();
    try {
      final account = await GoogleSignIn.instance.authenticate();
      final auth = account.authentication;
      final idToken = auth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw StateError(
          'Google did not return an ID token. '
          'Confirm the Web client ID is set as serverClientId.',
        );
      }
      return idToken;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> signOut() async {
    if (!_initialized && !AppConfig.hasGoogleSignInConfig) return;
    await _ensureInitialized();
    await GoogleSignIn.instance.signOut();
  }
}

final googleAuthServiceProvider = Provider<GoogleAuthService>((ref) {
  return GoogleAuthService();
});
