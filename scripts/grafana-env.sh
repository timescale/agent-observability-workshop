#!/usr/bin/env bash
#
# Write .env so Grafana can reach your Tiger Cloud service.
#
#   scripts/grafana-env.sh <service-name-or-id>
#   scripts/grafana-env.sh                      # uses your default service
#
# Reads the connection string from the Tiger CLI and splits it into the
# variables docker-compose hands to Grafana. .env is gitignored -- the password
# never lands anywhere you could commit it by accident.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve a name to an ID if one was given; otherwise use the default service.
target="${1:-}"
if [ -n "$target" ] && ! [[ "$target" =~ ^[a-z0-9]{10}$ ]]; then
    target="$(tiger service list -o json \
              | jq -r --arg n "$target" '.[] | select(.name == $n) | .service_id' | head -1)"
    if [ -z "$target" ]; then
        echo "No Tiger Cloud service by that name. You have:" >&2
        tiger service list -o json | jq -r '.[] | "  \(.name)  (\(.service_id))"' >&2
        exit 1
    fi
fi

uri="$(tiger db connection-string ${target:+"$target"} --with-password)"

# postgresql://user:password@host:port/database?...
proto_stripped="${uri#*://}"
creds="${proto_stripped%%@*}"
hostpart="${proto_stripped#*@}"

user="${creds%%:*}"
password="${creds#*:}"
hostport="${hostpart%%/*}"
dbpart="${hostpart#*/}"

cat > "$here/.env" <<EOF
TIGER_HOST=${hostport%%:*}
TIGER_PORT=${hostport##*:}
TIGER_USER=$user
TIGER_PASSWORD=$password
TIGER_DATABASE=${dbpart%%\?*}
EOF

echo "Wrote $here/.env for ${hostport%%:*}"
echo "Restarting Grafana so it picks it up..."
docker compose -f "$here/.devcontainer/docker-compose.yml" up -d --force-recreate >/dev/null 2>&1 || {
    echo "  (Grafana isn't running yet -- it will pick this up on next start)" >&2
    exit 0
}
echo "Grafana is on http://localhost:3000"
