#!/usr/bin/env bash
#
# Runs every time the container starts. Brings up Grafana.
#
# Why this isn't just `docker compose up -d` inline in devcontainer.json:
# postStartCommand can fire before the docker-in-docker daemon is accepting
# connections. When that happens compose fails, nothing binds port 3000, and
# the port never shows up in the Codespaces Ports tab -- with no obvious error
# anywhere. So wait for the daemon first.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

# docker compose refuses to start if env_file is missing.
if [ ! -f "$root/.env" ]; then
    cat > "$root/.env" <<'ENV'
TIGER_HOST=
TIGER_PORT=5432
TIGER_USER=
TIGER_PASSWORD=
TIGER_DATABASE=tsdb
ENV
fi

echo "==> Waiting for the Docker daemon"
for i in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
        echo "    ready after ${i}s"
        break
    fi
    sleep 1
done

if ! docker info >/dev/null 2>&1; then
    echo "!!! Docker daemon never came up. Start Grafana by hand once it does:" >&2
    echo "      docker compose -f .devcontainer/docker-compose.yml up -d" >&2
    exit 0   # don't fail container start over this
fi

echo "==> Starting Grafana"
if docker compose -f "$here/docker-compose.yml" up -d; then
    # Nudge the port so the Ports tab picks it up even if detection is slow.
    for i in $(seq 1 30); do
        curl -sf http://localhost:3000/api/health >/dev/null 2>&1 && {
            echo "    Grafana is up on port 3000"
            exit 0
        }
        sleep 1
    done
    echo "    Grafana started but isn't answering on 3000 yet -- give it a moment."
else
    echo "!!! Grafana failed to start. Try:" >&2
    echo "      docker compose -f .devcontainer/docker-compose.yml up -d" >&2
fi
exit 0
