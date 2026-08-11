# Expose local SpeedQuiz API on a public HTTPS URL (any device / any network).
# Requires: Docker Desktop + API already running (`docker compose up`).
#
# Usage (from repo root):
#   powershell -ExecutionPolicy Bypass -File scripts/dev_tunnel.ps1
#
# Then rebuild the app with the printed URL:
#   cd mobile
#   flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-SUBDOMAIN.trycloudflare.com

$ErrorActionPreference = "Stop"

Write-Host "Starting Cloudflare quick tunnel -> http://host.docker.internal:8000"
Write-Host "Leave this window open while testing. Ctrl+C stops the tunnel."
Write-Host ""

try { docker rm -f speedquiz-tunnel 2>$null | Out-Null } catch {}
docker run --name speedquiz-tunnel --rm cloudflare/cloudflared:latest tunnel --url http://host.docker.internal:8000

