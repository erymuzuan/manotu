# Back office: feedback, crash reports and AI agents

Maintainers triage what people send from the app (feedback, crash reports) in a Blazor back office. AI agents
(Claude Code on the build Mac) read the same data through an MCP server, propose fixes as draft PRs and draft replies.
People stay in charge of everything that leaves Manotu or touches a reporter. (Code and IDs keep the
legacy `Gimano` / `gimano-*` names.)

Design canvas: https://claude.ai/artifact/XBcon9bVauxY6gVjBf2Y8T

```
phone ──(consented, scrubbed)──▶ Api /api/v1/feedback, /crash-reports ──▶ Postgres ◀── Worker (retention sweep)
                                                                              ▲
             maintainer ──(passkey / password + emailed code)──▶ BackOffice (Blazor) ─┤
                                                                              │
 Claude Code ──(agt_ token, Tailscale)──▶ Api /mcp  (gimano-backoffice MCP) ──┤
                                    └──▶ Api /admin/v1 (REST twin)          ──┘
          └──▶ GitHub: agent/* branch + draft PR ──▶ maintainer merges ──▶ release ──▶ mark done (build n)
```

## Pieces

| Piece | Where | |
|---|---|---|
| Intake | `Gimano.Api` `POST /api/v1/feedback`, `POST /api/v1/crash-reports` | contacts encrypted on arrival (`ContactCrypto`, AES-GCM) |
| Data + rules | `Gimano.Core/BackOffice/` (`TriageService`, `CrashLifecycle`) | one service used by all three front doors |
| Back office UI | `Gimano.BackOffice` (Blazor, Interactive Server per page, Identity + passkeys) | port 5090 |
| Agent API | `Gimano.Api` `/admin/v1/*` and `/mcp` | `agt_` bearer tokens with scopes |
| Retention | `Gimano.Worker` `ReportRetentionJob` (hourly: `ReportRetention` + `BackOfficeRetention`) | deletes expired contacts, crash reports, tokens, audit rows |

## Crash grouping

`signature = sha256(exception \n top 5 app frames)` (`CrashScrubber.Signature`, docs/api.md "Crash reports"). App
frames are those containing `my.gimano` / `Gimano`; line numbers and `0x…` addresses are removed, so the same bug keeps
its signature across builds. Without app frames, the first 5 frames are used.

A group's lifecycle is `open → triaged → fixing → done`, plus `wont_fix` (stored by name in `crash_groups.status`).
Marking it `done` from the back office needs `fixedInBuild`: when a crash arrives from that build or a later one, the
group becomes **`regressed`** automatically; crashes from older builds still in use don't reopen it. Any other closed
group (`wont_fix`, or `done` without a fix build, e.g. set with `X-Admin-Key`) reopens as `open` on its next crash.
Counts and reopening happen in one atomic UPDATE (`CrashLifecycle.BumpAsync`). When a group is first marked done,
every open feedback item linked to it (`crashSignature`) gets a **reply draft** that a maintainer approves.

Crash reports keep no device token or location; the user id is kept only for the daily limit and `DELETE /me`, and is
never shown in the back office or to agents. Reports are deleted after 90 days; the group keeps its counts.

## Who sees what

| Field | Public GitHub issue | Agent token | Maintainer |
|---|---|---|---|
| Message, category, screen, rating, app version | yes | yes, fenced as untrusted | yes |
| Device model, screen size, OS | no | yes | yes |
| Area (2 dp ≈ 1 km) | no | yes | yes |
| Crash stack (scrubbed on the phone) | no | yes | yes |
| Screenshot | no | only if a maintainer shares that one image | yes |
| Email / WhatsApp | never | never (flags only) | reveal with a reason, audited |
| User id, device token, IP address | never | never | never |

- **Contacts** are stored only as AES-GCM ciphertext (`report_contacts`, bound to their report), with the key in host
  config (`Feedback:ContactKey`, env `FEEDBACK_CONTACT_KEY`, shared by api and backoffice). No API response contains
  them. Maintainers can reveal one in the back office after giving a reason; the audit log keeps the reason, never the
  values. A contact is deleted 30 days after its report closes (feedback `done`/`wont_fix`; for a crash report, its
  group `done`/`wont_fix`) and after 90 days at most. Reopening a feedback item or crash group stops the 30-day clock,
  so the contact again lives until 90 days after its report. Reporters can withdraw a feedback contact with
  `DELETE /api/v1/feedback/{id}/contact`, and `DELETE /me` removes all of theirs.
- Without `Feedback:ContactKey`, the API **drops** volunteered contacts instead of storing them.

## Agent access

Tokens are minted in the back office (**Agent access**). They are shown once, live at most 8 hours, and are stored
as sha256. They can be revoked at any time.

| Scope | Allows |
|---|---|
| `read` | queue, feedback, crash groups/events, builds, runs; screenshots only when shared. Every `GET /admin/v1/*` needs it |
| `triage:write` | status, severity, category, duplicate-of, crash link, note, github.com link, analysis, fixed-in build |
| `runs:write` | start a run, log steps, set branch (`agent/*` only), PR URL, summary, status (not `done`) |
| `replies:draft` | queue an Inbox reply for a maintainer to approve |

No scope reveals contacts, mints tokens, sends replies, marks runs done, registers builds, merges or deploys.
A feedback status change (by anyone) puts the standard status notice in the reporter's in-app Inbox, as the
`X-Admin-Key` endpoint does; written replies go out only when a maintainer approves them.

**Network:** `/admin` and `/mcp` answer 404 to requests that came through the public Cloudflare edge
(`CF-Connecting-IP` / `CF-Ray`). Agents use Tailscale (`http://100.101.150.9:5080`). `Admin:AllowedNetworks`
(CIDRs) can tighten this further, and `Admin:Enabled=false` turns both endpoints off.

**Production** (`deploy/docker-compose.prod.yml`) serves the back office publicly at `https://backoffice.manotu.app` through
IIS ARR on .13 (see deploy/PRODUCTION.md, "Back office and maintainer digest"); every sign-in needs the emailed code below. The agent endpoints stay **off** (`Admin__Enabled=false`) until
you turn them on. To enable them, set in `deploy/.env.prod`:

```
AGENT_ADMIN_ENABLED=true
AGENT_ADMIN_NETWORKS=100.64.0.0/10     # the CIDR agents connect from (here: Tailscale); one network
```

and recreate the api. `Admin__AllowPublic` stays `false`, so requests through Cloudflare get 404 either way, and the
network check uses the client address after the trusted-proxy forwarded headers (`EdgeSetup`).

**Prompt injection:** reporter-written text from the MCP tools is wrapped in `<untrusted-{nonce}>…</untrusted-{nonce}>`
with a notice. None of the tools can reach outside the back office, so the worst a hostile message can do is produce a bad
draft, and a person reads every draft before it goes out.

### MCP server `gimano-backoffice`

Streamable HTTP, stateless, at `POST /mcp`. Add it to Claude Code on the build Mac:

```bash
claude mcp add --transport http gimano-backoffice http://100.101.150.9:5080/mcp \
  --header "Authorization: Bearer agt_…"
```

| Tool | Scope | |
|---|---|---|
| `queue` | read | open feedback + crash groups, regressions first |
| `feedback_search`, `feedback_get` | read | filters: status, category, screen, platform, text, sinceDays |
| `feedback_screenshot` | read | image content; 403 unless shared |
| `crash_groups`, `crash_group`, `crash_events`, `crash_linked_feedback` | read | stack + distributions |
| `builds_resolve` | read | app build → git commit + symbols location |
| `feedback_triage`, `crash_triage` | triage:write | |
| `reply_draft` | replies:draft | held in the Replies outbox |
| `run_start`, `run_log`, `run_update` | runs:write | |

The REST twin is `/admin/v1` (`/queue`, `/feedback`, `/feedback/{id}`, `/feedback/{id}/screenshot`, `PATCH /feedback/{id}`,
`POST /feedback/{id}/replies`, `/crash-groups`, `/crash-groups/{sig}`, `/events`, `/feedback`, `PATCH /crash-groups/{sig}`,
`/builds`, `/builds/resolve`, `/runs`, `POST /runs`, `POST /runs/{id}/steps`, `PATCH /runs/{id}`); see `/scalar/v1`.

### The fix loop

1. A maintainer opens a crash group, clicks **Agent prompt** and pastes it into Claude Code in the repo checkout.
2. The agent runs `run_start`, reads `crash_group` / `crash_events`, runs `builds_resolve` and checks out that commit.
3. It reproduces the bug with a failing unit test, fixes it on `agent/<run>-<slug>`, runs the tests and opens a
   **draft** PR. It records the branch and PR (`run_update`) and its analysis (`crash_triage analysis=…`), then
   sets the run to `waiting_for_review`.
4. The maintainer reviews and merges on GitHub. Protect `master` so agent credentials can't merge.
5. After the release, the maintainer registers the build under **Releases** and marks the group `done` with its build
   number. Linked reporters get reply drafts. Approving one puts a `feedback_status` item in the reporter's in-app Inbox.

## Maintainer sign-in

ASP.NET Core Identity in the `backoffice` schema of the Manotu (`gimano`) database. Only emails in `BackOffice:Maintainers` can
register or stay signed in; removing an email signs that person out on their next request. Changing a password, 2FA or
passkeys signs the account's other sessions out (Identity security stamp, checked every 30 minutes).

**Emailed sign-in code, every time.** After the password or passkey, a 6-digit code goes to the maintainer's email through
Azure Communication Services (`BackOffice:EmailCode:AcsConnectionString`; prod uses `DIGEST_ACS_CONNECTION_STRING`). It is
Identity's TOTP from the account's security stamp (a 3-minute step, accepted for a few minutes), so a password change voids
outstanding codes. At most one email per 45 s per account; wrong passwords and wrong codes both count toward the 5-attempt
lockout; no browser is "remembered". The code is never logged. `BackOffice:EmailCode:Required` (default true) fails closed
without ACS: nobody can sign in. Dev on the tailnet sets it false (`BACKOFFICE_EMAIL_CODE_REQUIRED`). Code:
`Components/Account/EmailSignInCode.cs`, page `Account/LoginWithEmailCode`. Registering an invite also ends with a code, which
proves the address.

**No self-registration.** An account can only be created with a **one-time invite** minted on the host for one allowlisted email:

```powershell
docker compose -f deploy/docker-compose.yml run --rm backoffice invite me@example.com
# (locally: dotnet run --project backend/src/Gimano.BackOffice -- invite me@example.com)
```

It prints `…/Account/Register?invite=inv_…` (base URL from `BackOffice:PublicUrl`, default `http://100.101.150.9:5090`).
The invite works once, only for that email, expires after 24 hours, and only its sha256 is stored
(`backoffice."MaintainerInvites"`); minting a new one for the same email cancels the unused old one. A failed
registration (e.g. a weak password) leaves the invite usable. External-login account creation is disabled. Passkeys need a secure
context, so serve the back office over HTTPS, e.g. `tailscale serve --bg --https=443 http://localhost:5090` on WS556,
then open `https://<ws556>.<tailnet>.ts.net`. Over plain HTTP, use a password plus an authenticator app (2FA).

## Moderation (user content)

Reviews, photos and community places can be reported in the apps (`POST /reviews|photos|places/{id}/flag`). Three
reports from different users hide the item automatically; a maintainer then decides. **Service level: act on every
reported or auto-hidden item within 24 hours** (Apple guideline 1.2, Google Play UGC policy, and our Terms §3).

The queue is on the API with the maintainer key (`X-Admin-Key`, LAN/Tailscale only):

```
GET  /api/v1/admin/moderation?kind=review|photo|place&state=flagged|hidden   → ModerationItem[] (most-reported first)
POST /api/v1/admin/moderation/{kind}/{id}/hide          hide it (review hidden, photo rejected, place hidden)
POST /api/v1/admin/moderation/{kind}/{id}/restore       it's fine: visible again, its reports cleared (also "dismiss")
POST /api/v1/admin/moderation/{kind}/{id}/ban-author    ban the contributor: all of their reviews, photos, places and
                                                        active road reports are hidden; new contributions get 403
POST /api/v1/admin/moderation/{kind}/{id}/unban-author  lift the ban (hidden content stays hidden until restored)
```

`ModerationItem = {kind, id, placeId, status, flagCount, flags: [{reason, at?}], text?, mediaUrl?, authorName?,
authorRef?, authorBanned, createdAt}`. Authors appear only by display name and the opaque `authorRef` handle, never by
user id: act on an author through one of their items. Display names are filtered on set (word list, no links). Users can
also hide a contributor on their own device by `authorRef`, without telling the server.

Bans follow the pseudonymous model: a banned person can delete the account and start a new pseudonym, which then starts
at the lowest tier (votes weigh less, new places need more confirmations), and its content can be reported and banned again.

## Maintainer digest (worker)

Without it, nobody would know that feedback or reported content is waiting. `MaintainerDigestJob` checks every 15 minutes
and emails the maintainers (`Digest:To`) through Azure Communication Services:

- **Daily digest**, once between 08:00 and 09:00 Malaysia time (`Digest:SendAtHour`), skipped on quiet days: new
  feedback in 24 h by category, feedback not yet triaged and its oldest age, new / open / regressed crash groups,
  moderation items waiting (same predicates as the moderation queue) and how many are places held for review.
- **Moderation alert** when the oldest waiting item reaches 20 h, at most every 12 h, so the 24-hour promise holds.

It carries **counts and ages only**: no message text, contacts, display names, ids or coordinates, so nothing private
leaves the server in an email. The link points at the back office, which is reachable only over Tailscale/VPN. It is
off unless `Digest:AcsConnectionString` (env `DIGEST_ACS_CONNECTION_STRING`) and a recipient are set. State is in memory:
a worker restarted inside the send hour may send that day's digest twice, and one that is down for the whole hour skips it.

## Retention (worker, hourly)

| Data | Kept |
|---|---|
| Feedback (message, rating, device info, coarse location, screenshot) | 24 months |
| Road reports | unlinked from the reporter (and their votes deleted) about an hour after they expire |
| Contact details | 30 days after the report closes, 90 days max; the report is stored without the user id |
| Crash reports | 90 days (group counts stay) |
| Inbox items | 90 days |
| Agent tokens | deleted 30 days after expiry or revocation |
| Audit log | 1 year |
