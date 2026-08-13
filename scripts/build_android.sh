#!/usr/bin/env bash
# Build the Android app against the deployed API.
#
# Both --dart-define values are mandatory in practice, and getting either wrong
# fails quietly rather than loudly:
#
#   API_BASE_URL missing          -> falls back to 10.0.2.2:8000, so the app
#                                    only works on an emulator
#   API_BASE_URL = Railway domain -> IPv4 only, works on Wi-Fi and dies on
#                                    mobile data (see infrastructure/cloudflare-worker)
#   GOOGLE_SERVER_CLIENT_ID missing -> the Google button renders but sign-in
#                                    cannot complete
#
# Usage:
#   scripts/build_android.sh              # release APK (sideloading / testing)
#   scripts/build_android.sh appbundle    # AAB for Play Console
#   API_BASE_URL=https://staging... scripts/build_android.sh
set -euo pipefail

TARGET="${1:-apk}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The Cloudflare Worker, not Railway: it publishes AAAA so the app works on
# IPv6-only mobile networks. Override by exporting API_BASE_URL.
API_BASE_URL="${API_BASE_URL:-https://speedquiz-api.contact-pushkarchaturvedi.workers.dev}"

# The backend verifies Google ID tokens against this same Web client id, so
# read it from .env rather than keeping a second copy in sync by hand.
if [[ -z "${GOOGLE_SERVER_CLIENT_ID:-}" ]]; then
  if [[ -f "$REPO_ROOT/.env" ]]; then
    GOOGLE_SERVER_CLIENT_ID="$(grep -E '^GOOGLE_CLIENT_ID=' "$REPO_ROOT/.env" \
      | cut -d= -f2- | tr -d '\r' || true)"
  fi
fi

if [[ -z "${GOOGLE_SERVER_CLIENT_ID:-}" ]]; then
  echo "error: GOOGLE_SERVER_CLIENT_ID not set and GOOGLE_CLIENT_ID absent from .env" >&2
  echo "       Google Sign-In would build but never complete." >&2
  exit 1
fi

case "$TARGET" in
  apk|appbundle) ;;
  *) echo "error: target must be 'apk' or 'appbundle' (got '$TARGET')" >&2; exit 1 ;;
esac

# --- Firebase (push notifications) -------------------------------------------
# Optional, unlike the two above: without these the app builds and runs exactly
# as before, and multiplayer notifications land in the in-app inbox only. They
# are passed as dart-defines rather than a bundled google-services.json so a
# missing Firebase project is a quieter app, not a broken build.
#
# Values from Firebase console -> Project settings -> Your apps (Android).
FIREBASE_DEFINES=()
for key in FIREBASE_API_KEY FIREBASE_APP_ID FIREBASE_PROJECT_ID FIREBASE_SENDER_ID; do
  value="${!key:-}"
  if [[ -z "$value" && -f "$REPO_ROOT/.env" ]]; then
    value="$(grep -E "^${key}=" "$REPO_ROOT/.env" | cut -d= -f2- | tr -d '\r' || true)"
  fi
  if [[ -n "$value" ]]; then
    FIREBASE_DEFINES+=("--dart-define=${key}=${value}")
  fi
done

if [[ ${#FIREBASE_DEFINES[@]} -eq 4 ]]; then
  PUSH_STATUS="enabled"
elif [[ ${#FIREBASE_DEFINES[@]} -eq 0 ]]; then
  PUSH_STATUS="disabled (no FIREBASE_* values)"
else
  # A partial set is always a mistake: FirebaseOptions needs all four, so this
  # would build an app that silently never registers for push.
  echo "error: found ${#FIREBASE_DEFINES[@]}/4 FIREBASE_* values." >&2
  echo "       Set all of FIREBASE_API_KEY, FIREBASE_APP_ID," >&2
  echo "       FIREBASE_PROJECT_ID and FIREBASE_SENDER_ID, or none." >&2
  exit 1
fi

echo "Building $TARGET"
echo "  API_BASE_URL           $API_BASE_URL"
echo "  GOOGLE_SERVER_CLIENT_ID <${#GOOGLE_SERVER_CLIENT_ID} chars>"
echo "  push notifications     $PUSH_STATUS"

cd "$REPO_ROOT/mobile"
flutter build "$TARGET" --release \
  --dart-define=API_BASE_URL="$API_BASE_URL" \
  --dart-define=GOOGLE_SERVER_CLIENT_ID="$GOOGLE_SERVER_CLIENT_ID" \
  "${FIREBASE_DEFINES[@]}"

if [[ "$TARGET" == "apk" ]]; then
  ARTIFACT="build/app/outputs/flutter-apk/app-release.apk"
else
  ARTIFACT="build/app/outputs/bundle/release/app-release.aab"
fi
echo
echo "Built mobile/$ARTIFACT"

# The signing key decides whether Google Sign-In works at all — an unregistered
# SHA-1 fails as an instant picker dismissal that reads like a user cancel.
APKSIGNER="$(ls "${ANDROID_HOME:-$HOME/AppData/Local/Android/Sdk}"/build-tools/*/apksigner.bat 2>/dev/null | tail -1 || true)"
if [[ -n "$APKSIGNER" && "$TARGET" == "apk" ]]; then
  echo "Signed by:"
  "$APKSIGNER" verify --print-certs "$ARTIFACT" 2>/dev/null \
    | grep -iE "SHA-1 digest" | sed 's/^/  /' || true
fi
