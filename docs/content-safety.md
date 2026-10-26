# Public content safety (AI check for reviews, photos, notes, places)

Design: canvas "Manotu AI Content Safety" (https://claude.ai/artifact/7GoD79wMSp6jbHStS6PK4k). Reason codes: `docs/api.md`,
"Community places". The check is Claude Haiku 5.5 only, shares the US$20/week budget with the place check, and sees **only the
public text or image**: never user id, pseudonym, device, contact details or location. Private data never goes to it.

This page is the contract the apps and the backend build against. `docs/api.md` links here.

## Policy

Not accepted in public content: violence, crime, sexual content, national security / sensitive sites, spam and adverts, scams and
phishing, online gambling, drugs, harassment and hate, personal data and private homes, high-risk investment, loan sharks, MLM,
counterfeit and medical claims, 3R (race, religion, royalty), and **promotion** of alcohol, tobacco/vape and gambling (offers,
codes, links, WhatsApp/Telegram contacts, logos pushed in photos).

Accepted: a neutral mention ("a vape shop is next door"), and a real place that sells alcohol, hosts gambling or sells
tobacco/vape (listed with a warning). Reason codes are fixed (`PlaceScreening.ReasonCodes`); the apps show their own copy, never
model text.

## Place warnings

`Place` and `PlaceSummary` gain `warnings?: ("alcohol"|"gambling"|"tobacco")[]` (omitted when empty). Sources: the owner's tags
on `POST/PATCH /places` (`warnings?: string[]`), AI `sensitive_*` codes on a community place, and OSM tags (`shop=alcohol`,
`amenity=bar|pub|biergarten|casino`, `leisure=adult_gaming_centre`, `shop=bookmaker|lottery`, `shop=tobacco|e-cigarette`).
Apps show a banner with one icon per warning and a short line; the place stays listed and routable. "Not right? Tell us" =
`POST /places/{id}/flag {reason:"other"}`.

## Reviews

`POST /places/{id}/reviews` is screened (text; photos are screened separately). Outcomes:

| Verdict | Response |
|---|---|
| publish | `201 Review` as today, `moderation.state: "passed"` |
| hold | `201 Review` with `status: "hidden"`, `heldForReview: true`, `moderation.state: "held"` (a maintainer decides within 24 h) |
| no answer in 4 s | `201 Review`, hidden, `moderation.state: "checking"`; the worker finishes it, the result arrives in the Inbox |
| reject | `422 {code: "content_rejected", reasons: string[], safeText?: string}`; nothing is stored. `safeText` is the review without the offending part when one exists (so the app can offer "Post this part") |
| AI off / budget used up | as today (profanity and link filters only), `moderation.state: "skipped"` |

`Review` (owner view only) gains `moderation: {state: "passed"|"held"|"checking"|"rejected"|"skipped", reasons: string[], canAppeal: bool}`.
`PATCH /reviews/{id}` is screened the same way. `POST /reviews/{id}/appeal {note?: ≤200}` → `202` (once per review, held for a
maintainer). 3 AI rejections in 24 h pause posting for 24 h: `403 {code: "posting_paused", pausedUntil}`.

## Photos

`POST /photos` stays `201 Photo` with `status: "processing"`. After EXIF/GPS stripping the worker sends the image to Haiku. The
`Photo` becomes `published`, `rejected` or stays `processing` while held. The uploader's own `Photo` gains
`moderation?: {state: "passed"|"held"|"checking"|"rejected", reasons: string[], canAppeal: bool}` (other viewers see only
published photos). A rejected photo never blocks the review or place it belongs to. `POST /photos/{id}/appeal {note?}` → `202`.

## Report notes

`POST /reports` with a free-text `note`: a rejected note is dropped and the report still goes out. The response gains
`noteDropped: true` and `noteReasons: string[]`. Feedback (`POST /feedback`) is private, not blocked: only spam/abuse is
flagged for a maintainer.

## Inbox

New kinds: `content_published` (held item approved), `content_held`, `content_rejected` (with `reasons`, `canAppeal`), each with
`{subjectKind: "review"|"photo"|"place", subjectId, placeId, reasons}`.

## Brand watchlist

Server table of brand names with a group (`gambling`, `online_gambling`, `tobacco`, `high_risk_investment`, `loan_shark`,
`alcohol`) and two modes: `placeMode` (`warn` | `hold`) and `textMode` (`mention_ok` | `reject`). A pre-filter flags text or
place names that match (after normalising spacing and look-alike characters), and the match is sent to Haiku as context; Haiku
decides mention versus promotion. Maintainers edit it in the back office ("Brand watchlist", with a "test a sentence" box).
Brand names only; nothing private. Edits are logged.

## Privacy

Rejected text is not kept. Held items are visible to maintainers as public text + reason codes only (author is a pseudonym). Request
bodies are not logged. Images are sent to the model after metadata is stripped.
