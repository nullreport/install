# NullReport

Self-hosted penetration testing report generator. Write findings, manage
report sections, reuse a finding library, and export polished DOCX reports from
your own templates. Everything runs on your own machine: the app, the database,
and every report stay where you deploy them.

This repository contains only the installer and deployment files. It pulls
prebuilt, signed Docker images; there is no application source here.

- **Website:** https://nullreport.app
- **Documentation:** https://docs.nullreport.app

## Requirements

- A machine with [Docker](https://docs.docker.com/get-docker/) and the Docker
  Compose v2 plugin (`docker compose`).
- About 2 GB of free disk for the images and database.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/nullreport/install/main/install.sh | sh
```

The installer downloads the compose file, generates strong secrets into a local
`.env`, pulls the images, and starts the stack. When it finishes, open
http://localhost:3000.

### Options

Prefix the command with any of these:

```sh
# Activate a paid tier you purchased
TIER=pro LICENSE_KEY=NR-PRO-xxxxx  curl -fsSL https://raw.githubusercontent.com/nullreport/install/main/install.sh | sh

# Install into a specific directory
NULLREPORT_DIR=/opt/nullreport     curl -fsSL .../install.sh | sh

# Serve on a different port
FRONTEND_PORT=8080                 curl -fsSL .../install.sh | sh

# Bundle a local Ollama for on-device AI (heavier; runs AI on this machine)
WITH_OLLAMA=1                      curl -fsSL .../install.sh | sh
```

Re-running the installer is safe: it reuses your existing `.env`, so your
secrets and the data they encrypt are never rotated out from under you.

## Update

```sh
curl -fsSL https://raw.githubusercontent.com/nullreport/install/main/update.sh | sh
```

Run it from your install folder (or set `NULLREPORT_DIR`). It pulls the latest
images for your tier and restarts. Your database, uploads, and exports are
preserved.

## Tiers

NullReport ships as one stack with three tiers. The `TIER` value in your `.env`
selects which images are pulled.

| Tier | What you get |
|------|--------------|
| **Free** | Reports, findings, sections, a finding library, and DOCX export. Self-hosted, no time limit. |
| **Pro** | Everything in Free, plus AI assistance (local Ollama or your own OpenAI / Anthropic / Gemini key). |
| **Team** | Everything in Pro, plus multi-user collaboration: comments, activity history, and live presence. |

Paid feature code is physically absent from the free images, and the paid tiers
additionally require a valid license key, enforced at runtime. Buy a license at
https://nullreport.app.

## Manage the stack

From your install folder:

```sh
docker compose ps        # status
docker compose logs -f   # follow logs
docker compose down      # stop (your data persists in named volumes)
```

## Support

Found a bug or want a feature? Open an issue at [nullreport/feedback](https://github.com/nullreport/feedback). For help, licensing, or anything private, email support@nullreport.app.

## License

The scripts in this repo (the installer, update script, and Compose files) are
MIT licensed; see [LICENSE](LICENSE), so you can read and trust exactly what you
run. The NullReport application images they pull are commercial software,
governed by the End User License Agreement at https://nullreport.app; reverse
engineering them is not permitted. © 2026 NullReport.
