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
`POST /places/{id}/flag {reason:"other", warnings?: ["alcohol"|"gambling"|"tobacco", …]}`, which now works for **map (OSM) places** too
(see "Flagging a map place" below).

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
`PATCH /reviews/{id}` is screened the same way. `POST /reviews/{id}/appeal` → `202` (once per review, held for a maintainer; the note
is now **required**, see "Appeals"). 3 AI rejections in 24 h pause posting for 24 h: `403 {code: "posting_paused", pausedUntil}`.

## Photos

`POST /photos` stays `201 Photo` with `status: "processing"`. After EXIF/GPS stripping the worker sends the image to Haiku. The
`Photo` becomes `published`, `rejected` or stays `processing` while held. The uploader's own `Photo` gains
`moderation?: {state: "passed"|"held"|"checking"|"rejected", reasons: string[], canAppeal: bool}` (other viewers see only
published photos). A rejected photo never blocks the review or place it belongs to. `POST /photos/{id}/appeal {note?}` → `202`.

## Report notes

`POST /reports` with a free-text `note`: a rejected note is dropped and the report still goes out. The response gains
`noteDropped: true` and `noteReasons: string[]`. Feedback (`POST /feedback`) is private and is never blocked or rejected: the
message text (only the text: never contact details, device info, location or user id) goes to the same Haiku 5.5 with a separate
spam/abuse prompt, and a "reject" sets `suspectedSpam` on the feedback so the back office can show it. The API response is unchanged
(`201 {id, createdAt, contactToken?}`; the app learns nothing). Off, budget used up, a failed call or no answer in 3 s: no flag, silently.

## Appeals

"Ask for a review" is one request for all three kinds, `POST /api/v1/appeals`, with a compulsory reason and optional evidence photos.
Auth as for other contributions (bearer + request signature). Because a refused review is **not stored** on our side (`422`), the app
sends back the text the user chose to resubmit.

```
POST /api/v1/appeals          multipart/form-data
  refusalId   UUID, required     the app's id for this refusal. One appeal per refusalId per user (a second one: 409 already_appealed).
                                 kind=photo: the id of the refused photo (Photo.id). kind=review: a UUID the app made when POST /reviews answered 422.
                                 kind=place: any UUID (the place is identified by placeId).
  kind        required           review | photo | place
  placeId     required*          the place the content belongs to (kind=place: the user's own rejected community place, "c…"). *Not needed for
                                 kind=photo: it is taken from the photo.
  text        optional, ≤ 2000   kind=review: the refused text the user chose to resubmit (the "safeText" the app offered, or the original; links are
                                 stripped, profanity is refused with 400 on "text"). kind=place: the place text. Ignored for photo.
  rating      1..5               REQUIRED when kind=review (a review needs a rating); ignored otherwise
  reasons     repeated field     the refusal's reason codes as the app got them (e.g. reasons=alcohol_promo&reasons=external_contact in the form body;
                                 one comma-separated value is accepted too). Unknown codes are dropped; at most 4.
  note        REQUIRED           the user's reason, trimmed, 1 to 200 characters, friendly and without links
  photos      0..3 files         evidence images (JPEG, PNG or WebP, at most 5 MB each; field name "photos", repeat it)
→ 202 {"id": "<appeal uuid>", "status": "pending"}
→ 400 {code:"note_required"}            note missing, blank, over 200 characters or with links (the same code for all three)
→ 400 validation (field "photos")       more than 3 photos, or not JPEG/PNG/WebP, or under 200 px; (field "refusalId"|"kind"|"placeId"|"rating"|"text")
→ 413 {code:"photo_too_large"}          a photo over 5 MB
→ 409 {code:"already_appealed"}         this refusalId was already appealed by this user (also: the photo or place was already appealed another way)
→ 404 / 403 / 409                        the place or photo does not exist; is not the user's own; a photo/place that was not rejected
→ 429                                   more than 10 appeals a day
```

Errors are problem+json (`{type?, title, status, detail, code?}`), like the rest of the API. `code` is the stable part; the apps show their own copy.

What happens next:

| Kind | While pending | Approved by a maintainer | Denied |
|---|---|---|---|
| review | nothing is stored as a review; the appeal waits in the maintainer queue | the review is **created, published, for the author** (their `refusalId` text and `rating`), +3 points; Inbox `content_published` with `subjectKind:"review"`, `subjectId` = the **new review id** | Inbox `content_rejected`, `canAppeal:false`, `subjectKind:"review"`, `subjectId` = the `refusalId` |
| photo | the photo stays rejected (`canAppeal:false`); its files are kept | the existing approve path: the photo is published, the uploader earns +2, Inbox `content_published` (`subjectKind:"photo"`) | Inbox `content_rejected`, `canAppeal:false`, `subjectKind:"photo"`, `subjectId` = photo id |
| place | the place stays `rejected` and waiting (editing is refused with 409 until decided) | the existing approve path: the place goes live, Inbox `place_live` | Inbox `content_rejected`, `canAppeal:false`, `subjectKind:"place"`, `subjectId` = place id |

A denied appeal cannot be repeated. The Inbox item's `reasons` are the reason codes the app sent.

The older endpoints stay, for an item that **is** stored (a late-rejected review, a rejected photo): `POST /reviews/{id}/appeal` and
`POST /photos/{id}/appeal` take JSON `{"note": "…"}` or multipart (`note`, `photos`). They now also **require a note**
(`400 {code:"note_required"}`) and accept up to 3 evidence photos (same limits). `POST /places/{id}/appeal` is unchanged (note optional).
Use whichever fits: an app that always has the refused text and a `refusalId` can use `POST /appeals` for everything.

Evidence photos: stored privately (never served by `/media`), re-encoded to WebP so EXIF and GPS are dropped, visible to maintainers
only, never published and **never sent to the model**. In the queue a maintainer sees the kind, place, text, reason codes, note, evidence
and the author's pseudonym only. Retention: the appeal's text, note and evidence photos (and the note and photos of an older-style appeal) are
deleted **30 days after the decision**, by the retention worker, and immediately by `DELETE /me`. The appeal row (ids, kind, status,
times) is kept until the account is deleted so the same refusal cannot be appealed twice. Request bodies are not logged.

## Flagging a map place

`POST /places/{id}/flag {reason, warnings?}` used to work for community places only. It now accepts a map (OSM) place id too (`n…`, `w…`,
`r…`): `202`, once per user per place, `404` for an unknown id. The server stores the public place id, the reason, the warnings the user
suggested (only `alcohol`, `gambling`, `tobacco`) and the time, nothing else (no location). The place is **not changed** and stays listed:
the report waits for a maintainer (moderation queue, kind `place`, `status:"osm"`, with `suggestedWarnings`). Same limits as community
flags: one flag per user per place plus the normal request rate limit. The flags are deleted with the account.

## Inbox

New kinds: `content_published` (held item approved), `content_held`, `content_rejected` (with `reasons`, `canAppeal`), each with
`{subjectKind: "review"|"photo"|"place", subjectId, placeId, reasons}`. `subjectKind:"place"` appears only for a **denied place appeal**
(`content_rejected`, `canAppeal:false`); other place results keep `place_held` / `place_not_accepted` / `place_live`.

## Brand watchlist

Server table of brand names with a group (`gambling`, `online_gambling`, `tobacco`, `high_risk_investment`, `loan_shark`,
`alcohol`) and two modes: `placeMode` (`warn` | `hold`) and `textMode` (`mention_ok` | `reject`). A pre-filter flags text or
place names that match (after normalising spacing and look-alike characters), and the match is sent to Haiku as context; Haiku
decides mention versus promotion. Maintainers edit it in the back office ("Brand watchlist", with a "test a sentence" box).
Brand names only; nothing private. Edits are logged.

## Privacy

Rejected text is not kept (except what the user chooses to resubmit in an appeal, deleted 30 days after the decision). Held items are visible to maintainers as public text + reason codes only (author is a pseudonym). Request
bodies are not logged. Images are sent to the model after metadata is stripped.
