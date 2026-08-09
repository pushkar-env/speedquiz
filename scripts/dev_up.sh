#!/usr/bin/env bash
set -euo pipefail
cp -n .env.example .env || true
docker compose up --build -d
echo "Waiting for API..."
for i in {1..60}; do
  if curl -sf http://localhost:8000/health >/dev/null; then
    echo "API is healthy"
    curl -s http://localhost:8000/ready
    echo
    exit 0
  fi
  sleep 2
done
echo "API failed to become healthy"
docker compose logs api --tail=100
exit 1
