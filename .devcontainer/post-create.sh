#!/usr/bin/env bash
#
# Runs once, when the codespace is first created.
#
# Installs the Tiger CLI and jq. Every SQL statement in this workshop runs
# through `tiger db query`, so there is no psql and no database driver here.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Installing jq"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq

echo "==> Installing Tiger CLI"
# INSTALL_DIR is honoured by the install script, so the binary lands on PATH for
# every shell rather than in ~/bin where only a login shell would find it.
curl -fsSL https://cli.tigerdata.com | sudo INSTALL_DIR=/usr/local/bin sh

echo "==> Configuring Tiger CLI credential storage"
# Do not remove this. There is no keyring in a container -- no gnome-keyring, no
# secret-tool, no dbus -- so the default backend has nothing to write to, and
# `tiger auth login` reports success while leaving every later command unable to
# read the credentials back. It fails silently, which is the worst kind.
tiger config set password_storage pgpass

echo "==> Seeding an empty .env for Grafana"
# docker compose refuses to start if env_file is missing, and Grafana starts
# before you have created a service. Placeholder now; scripts/grafana-env.sh
# fills it in for real once your service exists. .env is gitignored.
if [ ! -f "$REPO_ROOT/.env" ]; then
    cat > "$REPO_ROOT/.env" <<'ENV'
TIGER_HOST=
TIGER_PORT=5432
TIGER_USER=
TIGER_PASSWORD=
TIGER_DATABASE=tsdb
ENV
fi

cat <<'BANNER'

  ────────────────────────────────────────────────────────────────
   Agent observability — container ready

   Installed: tiger, jq.  Grafana starts on port 3000.

   Next, from this terminal:
       tiger auth login --headless
       tiger service create --name agent-obs --cpu shared --memory shared
       scripts/grafana-env.sh agent-obs

   Then work through sql/1 .. sql/6. Creating a service also makes it
   your default, so no `tiger db query` below needs a service ID.
  ────────────────────────────────────────────────────────────────

BANNER
