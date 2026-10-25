# Writing the release notes

Start from the Android commits that `release.py plan` lists. Write for drivers, not developers:
say what changes for them, in a sentence each. Skip refactors, tests and tooling.

## Files per staged folder

- **`notes-ms.txt` / `notes-en.txt`**: 3–6 short lines, one change per line, no markdown. They feed
  the in-app update sheet through `version.json`. Malay is the primary language, and English is shown
  when the phone isn't set to Malay.
- **`release.md`**: the GitHub release body, bilingual headings with English text.

## release.md template

```markdown
**Manotu 0.3.2 for Android** (package `my.manotu.app`). Website: https://manotu.app · Built from <short sha>,
signed with the release key (certificate SHA-256 `b9baddcd63b3d74b8a374cb93df3278579ba4faeae121c35827d377e210bbec9`).

### Baharu · New
- …

### Pembetulan · Fixes
- …

### Privasi · Privacy
- … (only if something privacy-related changed; say what stays on the phone)

SHA-256 (manotu-0.3.2.apk): `<sha256>`
```

## Rules

- Brand: only "Manotu" in user-facing text. No "formerly Gimano" or "Dahulu Gimano". Package IDs and
  file names stay as they are.
- Accurate: only claim what the commits do. If a server change is needed for a feature, say so only
  if the server is already live.
- No internal names (class names, endpoints, agent names, commit hashes except the build line).
