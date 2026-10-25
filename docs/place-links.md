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
