# Direct public place links

Canonical web link: `https://manotu.app/p/?id=w1106132383`.
App hand-off: `manotu://place?id=w1106132383`.
This example opens Petronas Bukit Bunga (Eshah Filling Station). The OSM name currently returned by the API is Petronas.

Both apps validate the scheme, host, path and a single public ID: OSM `n`, `w`, `r` plus a positive numeric ID,
or community `c` plus 32 lowercase hexadecimal characters. Unknown parameters, credentials, ports, fragments,
private IDs and coordinates are rejected. They fetch the existing `GET /places/{id}` without visitor coordinates
and open the place card. They never save a favourite or start navigation automatically. Links received during
navigation ask the user to finish the drive first. Failed lookups show a retry message; newer links supersede pending ones.

Android registers verified `/p` and `/p/` App Links on manotu.app plus the custom scheme in the Manotu flavor.
The browser fallback offers an explicit Open in Manotu button and installation instructions; there is no automatic
redirect, tracking, clipboard access or private-data upload. Existing installations need an updated app.
iOS handles both forms, but automatic Universal Links depend on the individual Apple team's Associated Domains
entitlement and deployed association. Do not deploy the repository's placeholder TEAMID association file.

Web deployment is additive: publish `site/manotu/p/` to the canonical site and its bukitbunga mirror. Preserve
server-only root configuration and live association identities. Add `/p` and `/p/` to the existing iOS association
only when an approved individual-team identity is configured. No REST API contract or database change is needed.

## Navigate links (KhaiRider and other delivery apps)

Owner-approved 27 Oct 2026. A navigate link asks Manotu to route to a coordinate:

- App hand-off: `manotu://navigate?lat=3.1301&lng=101.6712&label=Kedai%20Ali`
- Web twin: `https://manotu.app/nav/?lat=3.1301&lng=101.6712&label=Kedai%20Ali` (also `/nav` without the slash)

**This deliberately differs from place links**, which reject coordinates: a navigate link is built by another app
for a delivery stop that has no public place ID, so it must carry the destination. The coordinates are the
sender's destination, not the user's location, and never reach a Manotu server.

Validation (Android, iOS and `site/manotu/nav/link.mjs` share one grammar; anything else is rejected whole):

- Scheme, host and path exactly as above. No credentials, port, fragment or whitespace; at most 512 characters.
- Only `lat`, `lng` and `label`, each at most once; `lat` and `lng` are required. Any other parameter, duplicate or empty
  pair is invalid.
- `lat` in [-90, 90] and `lng` in [-180, 180] as plain decimal strings: optional `-`, no `+`, no exponent, no leading
  zeros (`03.1`), no bare `.5` or `3.`, at most 6 decimals.
- `label` is optional, percent-encoded (spaces as `%20`, `+` is invalid), 1 to 60 characters after decoding, not blank. Allowed: letters
  (any script, with combining marks), digits, space and `. , - # / ( ) ' & @ :`. Control characters, angle brackets,
  newlines and anything that looks like a URL (`://`, `www.`) are rejected.

Behaviour in the apps:

- Show a confirmation sheet with the label and coordinates; never start navigation automatically. During an active
  drive, show "finish your drive first" and drop the link (same as place links; nothing is held or replaced); a newer link
  supersedes a pending one.
- Route with the user's currently selected vehicle profile. The phone's position is the start; if no fix is
  available yet, wait for one rather than guessing.
- Nothing is saved (no favourite, recent or trip entry is created until the user drives) and nothing is logged or sent
  server-side by the link itself. Routing uses the existing routing request, as for any destination the user picks.
- The label is plain text everywhere (no markup, no links).

Web fallback: `/nav/` validates the same rules, shows the pin, label and coordinates as plain text, and offers an
explicit Open in Manotu button (rebuilt from the validated values) plus install instructions, in Malay and English.
No automatic redirect, network call, tracking, clipboard access or storage. Invalid links show an error without
echoing the input.

Detection by KhaiRider: Android checks package `my.manotu.app` is installed (declare a `<queries>` entry);
iOS checks `canOpenURL` for the `manotu` scheme (add `manotu` to `LSApplicationQueriesSchemes`). Install the store
build when absent, then use `https://manotu.app/nav/` as the fallback link.

Deployment: additive publish of `site/manotu/nav/` to manotu.app and the bukitbunga `/manotu/` mirror. Universal
Links / App Links for `/nav` need the owner's association changes (see the release notes of this change); the custom
scheme and the explicit button work without them. No REST API or database change.
