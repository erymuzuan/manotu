# Explicit place approval and contributor replies

These operations require the existing protected `X-Admin-Key` admin credential. Do not put it in shell history,
request URLs, evidence or logs. They act on one explicitly verified submission at a time; there is no batch approval.

## Approve a verified public, nonduplicate submission

`POST /api/v1/admin/moderation/place/{submissionId}/restore`

An explicitly selected legacy `Pending`/screening `None` submission now becomes screening `Passed`, `listed=true`.
It stays `Pending` until community confirmation; no votes, points or verification thresholds are manufactured.
Unselected submissions are untouched. Existing held/rejected approval behavior remains. A `place.restore` audit
records the credential fingerprint and before/after status, screening and listing state without names/locations.
The normal `PlaceChanged` indexing and late `PlaceScreened` Inbox events are emitted. A repeated restore does
not re-emit the approval Inbox event once screening is already Passed. Indexing remains asynchronous: verify the
exact public place ID in search after the worker processes the event. Do not treat a successful POST as proof
of search visibility. Existing event delivery has no transactional outbox; monitor delivery failures normally.

## Reply to the contributor of an existing public submission

`POST /api/v1/admin/moderation/place/{submissionId}/reply`

```json
{
  "requestId": "f5f0d0e4-e841-40ad-850f-832c947e606e",
  "message": "Terima kasih kerana membantu Manotu.",
  "reason": "approved"
}
```

Persist one UUID requestId for each intended delivery and reuse it for retries. Message: 1–1000 characters
after trimming. Reason: `approved`, `duplicate`, `private_place`, `needs_information` or `other`. Messages must
only discuss the public contribution; never include private addresses, contacts, identities or credentials.
The service resolves the existing contributor internally; its response contains no user/contact ID.

Response: `{ "status": "sent", "inboxId": "…", "replay": false }`, or `recipient_unavailable` with a null
Inbox ID when the contributor no longer exists. Repeating the same request returns `replay=true`; changing
the text/reason under that requestId returns 409. A PostgreSQL transaction/advisory lock serializes concurrent
deliveries. Inbox insertion and the audit receipt commit together. Audit receipts retain the payload hash,
reason and outcome, not message text or recipient identity; they prevent resends even after Inbox retention.

This uses an individual `InboxItem` of the already-supported `announcement` kind, with a `place` reference and
custom stored title/body. It does not create a broadcast, feedback record, reputation penalty or place status
change. Both mobile clients already handle this kind and the server preserves its text. No migration needed.

Before a duplicate reply: confirm the submission and canonical existing ID, verify public detail and public
search return that exact existing ID near the public locality, then use the actual existing listing name.
If search fails, hold the acknowledgement and investigate. Never restore/approve a confirmed duplicate.

## WS556 validation and release

Base: origin/master `8bbf4c0`. SERVER must not build images or run tests. Tests use isolated PostGIS through
`GIMANO_PG_TEST`, never production. Run the executable xUnit runner (`dotnet run`, not VSTest `dotnet test`):

```powershell
dotnet run --project backend/tests/Gimano.Tests -- -class '*PlaceContributorReplyAuthTests' -parallel none
dotnet run --project backend/tests/Gimano.Tests -- -class '*PostgresIntegrationAddPlaceTests' -method '*Contributor_reply*' -method '*Explicit_restore*' -parallel none
```

Set `GIMANO_OS_URL` to isolated test OpenSearch too: the approval regression verifies public search before/after.
Require all 12 focused cases (5 auth, 7 database/search) to execute, with zero skips. Also run existing moderation/content-safety
regressions and the real OpenSearch tests before release. Review warnings. This is API-only code; build/push
only the API image on WS556 and record its immutable digest. Coordinate master push before release. Deploy
using the release runbook, preserve worker/backoffice/global TAG and search alias. No importer/reindex is needed.
No production place actions are implicit in deployment: only owner-verified IDs may be processed afterward.
