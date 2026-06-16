#!/usr/bin/env sh
# NullReport updater — pulls the latest images for your installed tier and
# restarts. Your data (database, uploads, exports) is preserved; only the app
# containers are recreated (~15-30s of downtime).
#
#   curl -fsSL https://raw.githubusercontent.com/nullreport/install/main/update.sh | sh
#
# Run it from where you installed NullReport, or point it at the folder (the
# variable goes on `sh`, not before curl):
#   curl -fsSL …/update.sh | NULLREPORT_DIR=/opt/nullreport sh
set -eu

DIR="${NULLREPORT_DIR:-nullreport}"

say() { printf '\033[1;35m▸\033[0m %s\n' "$1"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# If we're already inside the install dir (compose file present here), use it.
if [ -f docker-compose.yml ]; then
  :
elif [ -d "$DIR" ] && [ -f "$DIR/docker-compose.yml" ]; then
  cd "$DIR"
else
  die "Couldn't find a NullReport install. Run this from your install folder, or set NULLREPORT_DIR=/path/to/it."
fi

command -v docker >/dev/null 2>&1 || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 required."
docker info >/dev/null 2>&1 || die "Docker is installed but not running — start Docker Desktop (or the docker daemon) and re-run."

# Read a value from .env, tolerant of a trailing CR if the file was edited on
# Windows (a stray \r would otherwise corrupt the key / host).
env_val() { grep -E "^$1=" .env 2>/dev/null | cut -d= -f2- | tr -d '\r'; }

# Paid images are private; re-authenticate to the license registry before pull.
# A revoked or lapsed license is refused here, so updates simply stop.
TIER=$(env_val TIER)
if [ -n "${TIER:-}" ] && [ "$TIER" != "free" ]; then
  KEY=$(env_val LICENSE_KEY)
  RHOST=$(env_val REGISTRY_HOST)
  say "Authenticating to the license registry…"
  printf '%s' "$KEY" | docker login "${RHOST:-license.nullreport.app}" -u license --password-stdin >/dev/null \
    || die "License registry login failed — is your license still active?"
fi

say "Pulling the latest images…"
docker compose pull

say "Restarting…"
docker compose up -d --remove-orphans

# Reclaim space from the now-unused old image layers.
docker image prune -f >/dev/null 2>&1 || true

say "Updated — your data was preserved. Give it ~20s, then refresh."
