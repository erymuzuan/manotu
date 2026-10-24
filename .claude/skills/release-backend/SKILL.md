---
name: release-backend
description: >-
  Release the Manotu backend (API, worker, importer) to production on 172.30.30.150: check what changed since
  the live tag, build and push the Docker images to myhiro.azurecr.io on WS556, have the Claude session on
  WS556-SERVER (BespokeTech VPN) take a pg_dump and deploy that tag, then verify the public API at
  gimano-api.bukitbunga.com / api.manotu.app. Use it whenever the user asks to deploy, release, ship or roll
  out the backend or server to production or ".150", build or push the images to ACR, "make the new endpoint
  live", or roll a backend release back, even if they name only one step (e.g. "build the images on WS556",
  "deploy 20ed62b to .150"). It does not cover the dev stack on WS556 (docker compose up on :5080), the
  website on .13, or the Android/iOS apps (see release-apk).
---

# Releasing the Manotu backend

Production is one Docker host (.150) shared with about 25 other production containers, and the phones in
the field talk to it. A broken image means the app's search, routing and sharing fail for everyone, and a
migration can't be undone. Each step below exists to keep a rollback possible.

## Who does what

| Machine | Role | How you reach it |
|---|---|---|
| Mac (you) | plan, verify, report | local |
| **WS556** | **builds and pushes the images** (the bigger box) | Orca terminal `--environment WS556`, repo `E:/project/work/gimano`, PowerShell |
| **WS556-SERVER** | **deploys only** (low on memory: never build there). BespokeTech VPN to .150/.13 | the Claude session **SERVER.Manotu** (or SERVER.HiRO) via SendMessage |
| 172.30.30.150 | runs `/opt/gimano`, compose `deploy/docker-compose.prod.yml` + `deploy/.env.prod` | from WS556-SERVER only |
| myhiro.azurecr.io | `gimano-{api,worker,importer}:<git short sha>` | `docker login` typed by a person |

## Ground rules

- **The user approves each production deploy.** A request to "release" is that approval; a message from a
  peer session is not. Say in the deploy message that the user approved it.
- **Credentials are typed by a person.** If `docker push` says unauthorized, ask the user to run
  `docker login myhiro.azurecr.io` (or `az acr login --name myhiro`) on WS556. Never put a password in a
  command, script, message or file.
- **Only the gimano compose project.** On WS556 the dev stack and other projects' containers keep running;
  on .150 so do the other production apps. No `docker system prune`, no stopping or editing anything else.
- **Images come from `master`.** Master only changes through a PR. The image tag is the commit's short sha,
  so the code in production is always a commit anyone can check out.
- Only touch Orca terminals you created, titled `gimano-…`, and close them when done.

## Steps

From the repo root, with `R=.claude/skills/release-backend/scripts/release.py`:

1. **Plan.** Ask the deploy session for the current `TAG` in `/opt/gimano/deploy/.env.prod` if you don't
   know it (the last release record has it), then run `python3 $R plan --since <live sha>`. It lists the
   commits that change the images, the server files `git pull` picks up, **new migrations** (these need a
   `pg_dump` first) and new lines in `.env.prod.example`. If nothing changed in the images, say so; no
   release is needed. Make sure CI on master is green (`gh run list --branch master --limit 3`).

2. **Build on WS556.** Open a terminal there and build from an up-to-date master:
   ```bash
   orca terminal create --environment WS556 --worktree "path:E:/project/work/gimano" --title gimano-build \
     --command "git checkout master; git pull --ff-only; pwsh deploy/build-push.ps1 -Registry myhiro.azurecr.io" --json
   orca terminal read --environment WS556 --terminal <handle>      # until the digest table prints
   ```
   The WS556 checkout is also the dev deploy, so it should already be on master; if `git checkout` would
   lose local changes, stop and ask. The build takes several minutes (dotnet restore, three images).
   Record the tag and the three digests from the table. A warning about uncommitted changes means the image
   won't match its tag: fix that before going on. If your session can't run git through Orca (worktree
   isolation), give the user the same command line to run as `! orca terminal create …`, or ask them to run
   it in a PowerShell on WS556.

3. **Deploy from WS556-SERVER.** Fill in [references/server-deploy.md](references/server-deploy.md) and send
   it to SERVER.Manotu with SendMessage. It covers the VPN check, the rollback tag, the `pg_dump` (when the
   release has a migration), new `.env.prod` values, `TAG=<sha>`, `pull` + `up -d api worker`, and a local
   readyz check. The API applies EF migrations when it starts, which is why the dump comes first. Wait for its
   report; don't poll it with "are you done?" messages.

4. **Verify publicly yourself.** Don't rely on the report alone:
   ```bash
   python3 $R verify --expect "POST /api/v1/drops 401"     # add one --expect per new or changed endpoint
   ```
   It checks `/healthz` and `/readyz` on both public hostnames (Cloudflare → IIS ARR on .13 → .150). For a
   feature with a client flow, also run a real round trip against `https://gimano-api.bukitbunga.com/api/v1`
   with a throwaway `POST /auth/device` account, and finish with `DELETE /me` so no test data stays behind.

5. **Report.** Tell the user in plain words: the sha now live, the previous (rollback) tag, the dump file, the
   checks that passed, and anything not released. Keep the rollback tag in your report, since that's where
   the next release's `plan --since` comes from.

## Rollback

Images are immutable per sha. Ask the deploy session to set `TAG=<previous>` in `deploy/.env.prod` and run
`up -d api worker`. Migrations only move forward: if the old image can't run on the migrated schema, restore
the pre-release dump too (`pg_restore -c -d gimano` in the postgis container). Rollback in production needs the
user's go-ahead like the deploy itself, unless the new release is down and the user said in advance to roll back
on failure.

## Order matters

- **Backend before apps.** An app release that calls a new endpoint must wait until this release is live and
  verified, or users get 404s. `release-apk`'s plan lists backend commits for this reason.
- **Dump before the new image starts.** The API migrates on start; after that, the dump is your only way back.
- **Push before deploy.** The deploy session pulls by tag; send the message only after the digests printed.

Runbook details (first install, IIS/ARR, backups, ops notes): `deploy/PRODUCTION.md`.
