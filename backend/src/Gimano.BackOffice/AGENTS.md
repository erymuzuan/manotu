# Gimano.BackOffice (Manotu back office)

Maintainer back office for feedback, crash groups, agent runs and agent tokens. Product rules: `docs/back-office.md`
and the privacy rule in the root `AGENTS.md`.

| Setting | Value |
|---------|-------|
| **Interactivity Mode** | Server |
| **Interactivity Scope** | Per-page |

## Rendering configuration
Created with `dotnet new blazor -int Server -au Individual`. Pages are static SSR by default; pages with forms or
buttons that change data (`CrashGroup`, `FeedbackDetail`, `Replies`, `RunDetail`, `AgentAccess`, `Builds`) opt in
with `@rendermode InteractiveServer`. List pages (`Home`, `Crashes`, `FeedbackList`, `Runs`, `Audit`) filter with
plain GET forms and stay static.

## Data access
- Pages inherit `Components/Shared/BackOfficePage` (an `OwningComponentBase<TriageService>`), so each page gets its own
  `GimanoDbContext` scope. Go through `TriageService` (Gimano.Core/BackOffice): it applies the same rules and audit
  logging as the agent API. Don't query `GimanoDbContext` directly from a page.
- The main schema is migrated by Gimano.Api. This app migrates only its Identity tables (`backoffice` schema).
- Never render contact details except the result of `RevealContactAsync` (human only, reason required, audited).

## Authentication
ASP.NET Core Identity with passkeys is configured (`Data/ApplicationDbContext`, schema `backoffice`). Only emails in
`BackOffice:Maintainers` can register or stay signed in (`MaintainerUserValidator`, cookie `OnValidatePrincipal`).
There is no public registration. Google may provision/link only an explicitly allowlisted, verified Gmail identity;
other emails are denied. Password sign-in, registration/reset and identity-change pages are retired.
Passkey enrollment requires an authenticated moderator session. Preserve the emailed-code step for both sign-in methods.
Every page under `Components/Pages` requires sign-in (`_Imports.razor` has `[Authorize]`). The Identity pages under
`Components/Account/` are always static SSR: don't add `@rendermode` to them. They are the only pages that load Bootstrap.

## Environment constraints
- Interactive components run on the server via SignalR. `HttpContext` is available in static components but NOT in
  interactive components during the SignalR circuit lifetime; use `BackOfficePage.MeAsync()` for the signed-in maintainer.
- Passkeys need HTTPS (or localhost). Use HTTPS for development sign-in; password fallback is disabled.

## Don'ts
- Don't add `@rendermode InteractiveServer` to read-only pages.
- Don't set `@rendermode` on `<Routes>` in `App.razor`; that makes it global.
- Don't inject `HttpContext` in interactive components.
- Don't add third-party analytics, fonts beyond Google Fonts Nunito/JetBrains Mono, or tracking scripts.
