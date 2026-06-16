#!/usr/bin/env sh
# NullReport one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/nullreport/install/main/install.sh | sh
#
# Optional settings go on the `sh` at the END of the command. A variable placed
# before `curl` is handed to curl, not to the shell that runs this script, so it
# would be silently ignored.
#   curl -fsSL …/install.sh | LICENSE_KEY=NR-PRO-xxxxx sh   # tier detected from the key
#   curl -fsSL …/install.sh | NULLREPORT_DIR=/opt/nullreport sh
#   curl -fsSL …/install.sh | FRONTEND_PORT=8080 sh
#   curl -fsSL …/install.sh | WITH_OLLAMA=1 sh              # bundle local AI
#
# Idempotent: re-running reuses the existing .env so your secrets (and the
# data they encrypt) are never rotated out from under you.
set -eu

REPO_RAW="https://raw.githubusercontent.com/nullreport/install/main"
DIR="${NULLREPORT_DIR:-nullreport}"
TIER="${TIER:-free}"
LICENSE_KEY="${LICENSE_KEY:-}"
PORT="${FRONTEND_PORT:-3000}"
WITH_OLLAMA="${WITH_OLLAMA:-}"

say() { printf '\033[1;35m▸\033[0m %s\n' "$1"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# Upsert KEY=VALUE in ./.env: replace the existing line or append it. Used on a
# re-run to apply non-secret changes (an upgraded license key, the Ollama
# choice) without disturbing the generated secrets.
set_env() {
  _k=$1; _v=$2
  if [ -f .env ] && grep -q "^${_k}=" .env; then
    grep -v "^${_k}=" .env > .env.tmp || true
    printf '%s=%s\n' "$_k" "$_v" >> .env.tmp
    mv .env.tmp .env
  else
    printf '%s=%s\n' "$_k" "$_v" >> .env
  fi
}

# 0. License key drives the tier --------------------------------------------
# Take the key from the environment, or ask once when a terminal is attached
# (so a free-command run by someone who actually has a key still works). A
# doubled prefix like NR-PRO-NR-PRO-… (a common paste slip) is repaired.
normalize_key() { printf '%s' "$1" | tr -d '[:space:]' | sed -E 's/^NR-(PRO|TEAM)-NR-(PRO|TEAM)-/NR-\1-/'; }
LICENSE_KEY=$(normalize_key "$LICENSE_KEY")

if [ -z "$LICENSE_KEY" ] && [ -r /dev/tty ]; then
  printf '\033[1;35m▸\033[0m Paste your Pro/Team license key (or press Enter for the free tier): '
  read ans </dev/tty || ans=""
  LICENSE_KEY=$(normalize_key "$ans")
fi

# The key determines the tier; a TIER that disagrees with the key is ignored.
case "$LICENSE_KEY" in
  NR-PRO-*)  TIER=pro ;;
  NR-TEAM-*) TIER=team ;;
  "")        TIER=free ;;
  *) die "That doesn't look like a NullReport license key (expected NR-PRO-… or NR-TEAM-…)." ;;
esac

# Image references. Free images are public on ghcr (no login). Paid images are
# private and pulled through the license server's registry doorman, which checks
# the license key at `docker login` time.
GHCR_OWNER="izzy0101010101"
REGISTRY_HOST="${REGISTRY_HOST:-license.nullreport.app}"
if [ "$TIER" = "free" ]; then
  BACKEND_IMAGE="ghcr.io/$GHCR_OWNER/nullreport-backend:free"
  FRONTEND_IMAGE="ghcr.io/$GHCR_OWNER/nullreport-frontend:free"
else
  BACKEND_IMAGE="$REGISTRY_HOST/nullreport-backend-paid:$TIER"
  FRONTEND_IMAGE="$REGISTRY_HOST/nullreport-frontend-paid:$TIER"
fi

# 1. Preflight ---------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "Docker is not installed — see https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 required (the 'docker compose' plugin)."
command -v curl >/dev/null 2>&1 || die "curl is required."
# The CLI can be present while the engine is stopped; catch that here rather
# than letting `docker login`/`pull` fail later with a cryptic socket error.
docker info >/dev/null 2>&1 || die "Docker is installed but not running — start Docker Desktop (or the docker daemon) and re-run."

# A non-numeric or out-of-range port becomes an opaque compose error otherwise.
case "$PORT" in ''|*[!0-9]*) die "FRONTEND_PORT must be a number (got '$PORT')." ;; esac
{ [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; } || die "FRONTEND_PORT must be between 1 and 65535 (got '$PORT')."

# 1b. Authenticate FIRST, so a bad or mistyped key fails fast — before we prompt
# for Ollama or download anything. Paid images are private; free needs no login.
if [ "$TIER" != "free" ]; then
  say "Authenticating to the license registry…"
  printf '%s' "$LICENSE_KEY" | docker login "$REGISTRY_HOST" -u license --password-stdin >/dev/null \
    || die "License registry login failed — check your license key is correct and active (see your portal)."
fi

# 2. Workspace ---------------------------------------------------------------
mkdir -p "$DIR"
cd "$DIR"

# 3. Compose file ------------------------------------------------------------
say "Downloading docker-compose.prod.yml…"
curl -fsSL "$REPO_RAW/docker-compose.prod.yml" -o docker-compose.yml || die "Could not download the compose file."

# Optional: bundle Ollama for local AI. A preset WITH_OLLAMA is an explicit
# choice (1 = yes, anything else = no); otherwise ask when interactive. Track
# whether a choice was actually made so a re-run only rewrites COMPOSE_FILE when
# the user decided — never silently strips Ollama from a non-interactive re-run.
OLLAMA_EXPLICIT=""
if [ -n "$WITH_OLLAMA" ]; then
  OLLAMA_EXPLICIT=1
elif [ -r /dev/tty ]; then
  printf '\033[1;35m▸\033[0m Set up local AI with Ollama (runs AI on this machine, ~heavy)? [y/N] '
  read ans </dev/tty || ans=""
  case "$ans" in [Yy]*) WITH_OLLAMA=1 ;; *) WITH_OLLAMA="" ;; esac
  OLLAMA_EXPLICIT=1
fi
COMPOSE_FILES="docker-compose.yml"
if [ "$WITH_OLLAMA" = "1" ]; then
  say "Including bundled Ollama…"
  curl -fsSL "$REPO_RAW/docker-compose.ollama.yml" -o docker-compose.ollama.yml || die "Could not download the Ollama override."
  COMPOSE_FILES="docker-compose.yml:docker-compose.ollama.yml"
fi

# 4. Secrets / .env — generate ONCE; never rotate (would orphan encrypted data)
gen() { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

ADMIN_PW=""
FRESH_INSTALL=""
if [ -f .env ]; then
  say "Reusing existing .env (secrets preserved)."
  umask 077  # keep .env (and the .env.tmp set_env writes) owner-only

  # Apply an upgraded/changed license key on re-run. Tier, key, registry host and
  # image refs are NOT secrets, so updating them is safe — this is how
  # `curl … | LICENSE_KEY=… sh` upgrades an existing install. Only when a key was
  # actually supplied this run: a keyless re-run must not downgrade paid to free.
  if [ -n "$LICENSE_KEY" ]; then
    set_env TIER "$TIER"
    set_env LICENSE_KEY "$LICENSE_KEY"
    set_env REGISTRY_HOST "$REGISTRY_HOST"
    set_env BACKEND_IMAGE "$BACKEND_IMAGE"
    set_env FRONTEND_IMAGE "$FRONTEND_IMAGE"
    say "Applied license key (tier: $TIER)."
  fi

  # Reflect an explicit Ollama choice (preset or answered at the prompt). With no
  # explicit choice we leave the existing COMPOSE_FILE untouched, so a plain
  # re-run never silently adds or removes local AI.
  if [ -n "$OLLAMA_EXPLICIT" ]; then
    set_env COMPOSE_FILE "$COMPOSE_FILES"
  fi
else
  say "Generating secrets…"
  umask 077
  # A friendly first-run admin password, surfaced to the operator at the end so
  # they don't have to dig through container logs. Rotated on first sign-in.
  ADMIN_PW=$(openssl rand -hex 6 2>/dev/null || gen | cut -c1-12)
  FRESH_INSTALL=1
  cat > .env <<EOF
# Generated by install.sh. KEEP THIS FILE — rotating these after first run
# makes already-stored data unreadable.
JWT_SECRET=$(gen)
ENCRYPTION_KEY=$(gen)
POSTGRES_PASSWORD=$(gen)
TIER=$TIER
LICENSE_KEY=$LICENSE_KEY
REGISTRY_HOST=$REGISTRY_HOST
BACKEND_IMAGE=$BACKEND_IMAGE
FRONTEND_IMAGE=$FRONTEND_IMAGE
ADMIN_INITIAL_PASSWORD=$ADMIN_PW
FRONTEND_PORT=$PORT
# Used by the backend for CORS/links; keep it in step with FRONTEND_PORT. If you
# put NullReport behind a domain, set this to that URL (see the docs).
FRONTEND_URL=http://localhost:$PORT
COMPOSE_FILE=$COMPOSE_FILES
EOF
fi

# 5. Launch ------------------------------------------------------------------
# (Registry auth already happened up top, before the Ollama prompt.)
say "Pulling images (tier: $TIER)…"
docker compose pull
say "Starting…"
# --remove-orphans so toggling Ollama off on a re-run actually stops its container.
docker compose up -d --remove-orphans

printf '\n'
say "NullReport is starting at http://localhost:$PORT"
say "First boot runs DB setup — give it ~20s, then refresh."
if [ -n "$FRESH_INSTALL" ]; then
  say "Log in as  admin  /  $ADMIN_PW   (you'll set a new password on first sign-in — save this one)"
fi
if [ "$WITH_OLLAMA" = "1" ]; then
  say "Local AI is bundled — open Settings → AI → Ollama and click a model to download it."
fi
say "Manage it from the '$DIR' folder: docker compose ps | logs -f | down"
