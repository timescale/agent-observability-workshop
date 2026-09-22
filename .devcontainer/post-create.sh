#!/usr/bin/env bash
#
# Runs once, when the codespace is first created.
#
# Installs the Tiger CLI. Add whatever else your workshop needs below.

set -euo pipefail

echo "==> Installing Tiger CLI"
# INSTALL_DIR is honoured by the install script, so the binary lands on PATH for
# every shell. Don't install to ~/bin and symlink afterwards — that only works
# because Debian's .profile happens to add ~/bin in a login shell, and the
# installer itself warns the directory isn't on PATH.
curl -fsSL https://cli.tigerdata.com | sudo INSTALL_DIR=/usr/local/bin sh

echo "==> Configuring Tiger CLI credential storage"
# Do not remove this. There is no keyring in a container — no gnome-keyring, no
# secret-tool, no dbus — so the default backend has nothing to write to, and
# `tiger auth login` reports success while leaving every later command unable to
# read the credentials back. It is the single most common way this setup breaks,
# and it fails silently.
tiger config set password_storage pgpass

# Anything else your workshop needs goes here, e.g.:
#   sudo apt-get update -qq
#   sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq
# Prefer apt or a tool's own installer over ghcr.io/devcontainers-contrib/*
# features, which have failed to resolve during container creation before.

cat <<'BANNER'

  ────────────────────────────────────────────────────────────────
   <Workshop Name> — container ready

   Installed: tiger

   Next, from this terminal:
       tiger auth login --headless
       tiger service create --name <workshop>-workshop --cpu 500 --memory 2

   Creating a service also makes it your default, so no later
   `tiger db query` needs a service ID.
  ────────────────────────────────────────────────────────────────

BANNER
