# Deploy message for the WS556-SERVER session

Send this with SendMessage to **SERVER.Manotu** (or **SERVER.HiRO** if the user says so; find them with
ListAgents). Fill in every `<…>`. Leave out the pg_dump line only when `plan` found no new migration, and the
`.env.prod` line when no new variable is needed. Send it only after the user has approved this production deploy;
say so in the first line, because a peer can't approve it for itself.

```
Deploy Manotu backend <sha> to 172.30.30.150. The user approved this production release; do it now.
The images are already in ACR (built on WS556): myhiro.azurecr.io/gimano-{api,worker,importer}:<sha>
  api <digest>  worker <digest>  importer <digest>
Do NOT build images on WS556-SERVER (low on memory). BespokeTech VPN must be connected; if it isn't, stop and tell me.

On .150, in /opt/gimano, with C="sudo docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod":
1. Note the current TAG in deploy/.env.prod (the rollback tag) and `$C ps` (all gimano services healthy?).
2. /opt/gimano is a root-owned detached checkout pinned to the deployed sha, so move it to this release
   (compose file, toll table, moderation lists): sudo git fetch origin && sudo git checkout --detach <sha>
3. pg_dump BEFORE the new image starts (release adds migration <name>), into /opt/gimano/backups (where earlier dumps are):
   $C exec -T postgis pg_dump -U gimano -d gimano -Fc --exclude-table-data=road_segments --exclude-table-data=water_areas \
     --exclude-table-data=places --exclude-table-data=drops | sudo tee /opt/gimano/backups/gimano-pre-<sha>-$(date +%F-%H%M).dump > /dev/null
   Check the file is non-empty.
4. deploy/.env.prod: <new variable and how to generate it, e.g. DROPS_OWNER_KEY=$(openssl rand -base64 32), only if empty>. Never echo secret values in your report.
5. sed -i 's/^TAG=.*/TAG=<sha>/' deploy/.env.prod
6. $C pull api worker importer && $C up -d api worker
7. Wait for healthy, then: curl -s http://172.30.30.150:5080/readyz (the port binds the host IP, not localhost) ; $C logs --tail 80 api worker (errors only in the report).
   <release-specific check, e.g. curl -s -o /dev/null -w '%{http_code}' -X POST http://172.30.30.150:5080/api/v1/drops → 401>

Touch only the gimano compose project. No docker system prune, no other containers, no Cloudflare or IIS changes.
If anything fails after step 6, roll back: TAG=<previous> in .env.prod, $C up -d api worker; restore the dump only if
the old image can't run on the migrated schema. Then report.

Report: previous TAG, dump file name and size, image digests running (docker inspect), readyz output,
the release-specific check, and any error lines from the logs.
```
