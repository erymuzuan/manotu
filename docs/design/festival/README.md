# Festival design report

Open `index.html` in a browser. All illustrations, styles and interactions are local; no external fonts, scripts, maps or analytics load. Source links open only when clicked. The report is a proposal, not working event software. Keep the assets folder alongside it.

Adapted from the requested Design Report reference into responsive HTML, retaining the cover composition, typography hierarchy and section sequence. The original DOCX is unchanged. The requested frontend-design skill was not installed; responsive HTML/CSS was authored directly.

## Desktop extension

[Desktop and route planning specification](spec.md) describes the proposed Rust-backed app for macOS, Windows and Linux, complete event authoring, Garmin Connect-inspired route planning jobs, privacy gates and a copy-ready Claude `/design` prompt. The report includes a desktop workspace illustration. This is design only.

## Assets and generation

- `assets/festival-cover.png`: generated with built-in imagegen, then copied into this workspace.
- `assets/event-map.svg`: fictional map illustration authored in SVG.
- `assets/architecture.svg`, `assets/collaboration.svg`, `assets/lifecycle.svg`: authored vector diagrams.

Exact imagegen prompt:

```text
Use case: illustration-story
Asset type: cover illustration for a Malaysian private group event navigation design report
Primary request: a warm editorial illustration of a Malaysian kampung wedding gathering and a small cycling tour arriving, with a shaded lunch canopy, discreet parking area and winding village road connecting them, suggesting shared journeys and hospitality.
Style/medium: sophisticated hand-painted gouache editorial landscape, natural foliage, understated detail, warm olive, cream, terracotta palette.
Composition/framing: wide landscape composition, no UI or map labels. People small in scene, inclusive Malaysian gathering with varied modest everyday attire.
Lighting/mood: dappled late-afternoon tropical light, welcoming and calm.
Constraints: no text, no logos, no watermark; fictional setting; avoid identifiable real people.
```

## Verification

Chromium desktop (1440px) and mobile (390px): all images loaded, section anchors resolved, no page overflow at mobile width, no JavaScript errors. Scenario switching, next-stop preview, expiry and reset passed. All local source links resolve. Diagrams intentionally scroll within their containers on narrow screens. Print styles are provided; the HTML is the primary deliverable.

The architectural design explicitly identifies route caching, offline routing, invitation forwarding, anonymity limits and non-enforceable deletion of delivered copies. No product code or API contracts changed.
