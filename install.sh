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

# If launched from a directory that no longer exists (e.g. it was just deleted
# with `rm -rf` from inside it), the shell's working directory is broken and
# every subcommand prints "getcwd"/"chdir" errors. Step into $HOME so the run is
# clean. A relative NULLREPORT_DIR then resolves under $HOME.
if ! pwd -P >/dev/null 2>&1; then
  cd "$HOME" 2>/dev/null || cd / 2>/dev/null || true
fi

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

# Tier handling. The server is authoritative: any paid key's real tier is read
# from /api/license/activation-status in step 1b and overrides whatever we guess
# here. Current keys are tier-neutral (NR-<random>); older keys carry an
# NR-PRO-/NR-TEAM- prefix that can be stale after a plan change. We accept both:
# the legacy prefix is used only as a fallback hint if the server is unreachable.
case "$LICENSE_KEY" in
  "")        TIER=free ;;
  NR-TEAM-*) TIER=team ;;   # legacy prefix, fallback hint only
  NR-PRO-*)  TIER=pro ;;    # legacy prefix, fallback hint only
  NR-*)      TIER=pro ;;    # tier-neutral key: provisional; server decides the real tier
  *) die "That doesn't look like a NullReport license key (it should start with NR-)." ;;
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

  # A license activates exactly ONE machine. If it's already bound elsewhere and
  # this is a fresh install (no local instance to re-bind), runtime activation
  # will be refused and the app falls back to Free. Warn now rather than letting
  # the operator discover it after the fact.
  PROJECT=$(basename "$DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
  STATUS=$(curl -fsS --max-time 8 -X POST "https://$REGISTRY_HOST/api/license/activation-status" \
    -H 'Content-Type: application/json' -d "{\"licenseKey\":\"$LICENSE_KEY\"}" 2>/dev/null || true)

  # The key prefix can be stale after a plan change, so trust the server's tier
  # over the prefix and re-point the image refs if they differ. If the server
  # didn't answer (offline / older server), keep the prefix-derived tier.
  SERVER_TIER=$(printf '%s' "$STATUS" | sed -n 's/.*"tier":"\([a-z]*\)".*/\1/p')
  if { [ "$SERVER_TIER" = "pro" ] || [ "$SERVER_TIER" = "team" ]; } && [ "$SERVER_TIER" != "$TIER" ]; then
    say "Your license is '$SERVER_TIER' (the key label still says '$TIER' from when it was issued). Using the $SERVER_TIER image."
    TIER="$SERVER_TIER"
    BACKEND_IMAGE="$REGISTRY_HOST/nullreport-backend-paid:$TIER"
    FRONTEND_IMAGE="$REGISTRY_HOST/nullreport-frontend-paid:$TIER"
  fi

  case "$STATUS" in
    *'"activated":true'*)
      # No local app-data volume => brand-new machine identity => won't match the
      # bound machine. (A same-machine reinstall keeps app-data and re-activates.)
      if ! docker volume inspect "${PROJECT}_app-data" >/dev/null 2>&1; then
        printf '\033[1;33m▸ Heads up:\033[0m this license is already activated on another machine.\n'
        printf '  This is a fresh install, so it will run as the \033[1mFree\033[0m tier until you\n'
        printf '  deactivate that machine in your portal: https://portal.nullreport.app\n'
        printf '  (Reinstalling on the same machine? Ignore this.)\n'
        if [ -r /dev/tty ]; then
          printf '\033[1;35m▸\033[0m Press Enter to continue as Free, or Ctrl-C to cancel and deactivate first. '
          read _ans </dev/tty || true
        fi
      fi
      ;;
  esac
fi

# 2. Workspace ---------------------------------------------------------------
mkdir -p "$DIR"
cd "$DIR"

# 3. Compose file ------------------------------------------------------------
say "Downloading docker-compose.prod.yml…"
curl -fsSL "$REPO_RAW/docker-compose.prod.yml" -o docker-compose.yml || die "Could not download the compose file."

# Optional: bundle Ollama for local AI. One rule: offer it when the tier is PAID
# and it is NOT already set up.
#   - free            -> never (the free image has no AI routes); ignore WITH_OLLAMA.
#   - WITH_OLLAMA set -> honor it (1 = add, anything else = remove).
#   - paid, not bundled yet -> ask (a fresh paid install OR a free->paid upgrade).
#   - paid, already bundled -> stay quiet (a re-run never nags or strips it).
# "Already bundled" = the saved COMPOSE_FILE in .env includes the Ollama override.
# OLLAMA_EXPLICIT marks that a choice was made THIS run, so the .env COMPOSE_FILE
# is only rewritten when the user actually decided (never silently changed).
OLLAMA_EXPLICIT=""
if [ "$TIER" = "free" ]; then
  if [ "$WITH_OLLAMA" = "1" ]; then
    say "Ignoring WITH_OLLAMA: local AI is a Pro/Team feature, so a free install can't use it."
  fi
  WITH_OLLAMA=""
elif [ -n "$WITH_OLLAMA" ]; then
  OLLAMA_EXPLICIT=1
else
  _has_ollama=""
  [ -f .env ] && grep -Eq '^COMPOSE_FILE=.*ollama' .env && _has_ollama=1
  if [ -z "$_has_ollama" ] && [ -r /dev/tty ]; then
    printf '\033[1;35m▸\033[0m Set up local AI with bundled Ollama (runs AI on this machine, ~heavy)? [y/N] '
    read ans </dev/tty || ans=""
    case "$ans" in [Yy]*) WITH_OLLAMA=1 ;; *) WITH_OLLAMA="" ;; esac
    OLLAMA_EXPLICIT=1
  fi
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
  # A fresh .env gets a brand-new random POSTGRES_PASSWORD. If a database volume
  # from a previous install still exists, Postgres keeps the password baked into
  # that volume on first init and rejects the new one — the backend then
  # crash-loops with "P1000: Authentication failed". Catch it here with a clear
  # fix instead of a confusing loop.
  PROJECT=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
  if command -v docker >/dev/null 2>&1 && docker volume inspect "${PROJECT}_db-data" >/dev/null 2>&1; then
    die "Found a leftover database from a previous install ('${PROJECT}_db-data') with no .env to match its password — a fresh install would fail to connect. Wipe it for a clean start:
    cd '$DIR' && docker compose down -v
  then re-run this installer. (To keep that old data instead, restore its original .env rather than reinstalling.)"
  fi
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
# Up-front auth (above) is keyed on THIS run's tier. On a re-run of a paid
# install without re-supplying the key, that was skipped but .env still points at
# the private paid registry — so authenticate from the saved key before pulling,
# or the pull fails cryptically when the host has no/expired cached credential.
if [ -z "$LICENSE_KEY" ] && [ -f .env ]; then
  ENV_TIER=$(grep -E '^TIER=' .env | cut -d= -f2- | tr -d '\r')
  if [ -n "$ENV_TIER" ] && [ "$ENV_TIER" != "free" ]; then
    ENV_KEY=$(grep -E '^LICENSE_KEY=' .env | cut -d= -f2- | tr -d '\r')
    ENV_RHOST=$(grep -E '^REGISTRY_HOST=' .env | cut -d= -f2- | tr -d '\r')
    say "Re-authenticating to the license registry (saved key)…"
    printf '%s' "$ENV_KEY" | docker login "${ENV_RHOST:-license.nullreport.app}" -u license --password-stdin >/dev/null \
      || die "License registry login failed — your saved license may be inactive (see your portal)."
  fi
fi

say "Pulling images (tier: $TIER)…"
docker compose pull
say "Starting…"
# --remove-orphans so toggling Ollama off on a re-run actually stops its container.
docker compose up -d --remove-orphans

# Poll the API (through the frontend proxy) so the success line only prints once
# the app is actually serving — first boot runs migrations + seed before it answers.
printf '\n'
say "Waiting for NullReport to come up…"
ready=""
i=0
while [ "$i" -lt 90 ]; do
  if curl -fsS -o /dev/null --max-time 2 "http://localhost:$PORT/api/health" 2>/dev/null; then ready=1; break; fi
  i=$((i + 1)); sleep 1
done
if [ -n "$ready" ]; then
  say "NullReport is up at http://localhost:$PORT"
else
  say "Started, but the app didn't answer within 90s. Check: cd '$DIR' && docker compose logs -f"
fi
if [ -n "$FRESH_INSTALL" ]; then
  say "Log in as  admin  /  $ADMIN_PW   (you'll set a new password on first sign-in — save this one)"
fi
if [ "$WITH_OLLAMA" = "1" ]; then
  say "Local AI is bundled — open Settings → AI → Ollama and click a model to download it."
fi
say "Manage it from the '$DIR' folder: docker compose ps | logs -f | down"
