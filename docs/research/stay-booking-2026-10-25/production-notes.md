# Production notes

Research date: 25 October 2026.

## Design plan and review

- Ocean #226c93; ink #16384d; jade #18725b; pale sky #eaf3f7; white #ffffff; amber #faebce.
- Avenir Next / Avenir with system sans-serif fallbacks. No remote fonts.
- Travel-journal layout: large journey illustration, quiet recommendation panel, left navigation and a continuous reading column. Left-aligned body text.
- The distinctive element is the Malaysian accommodation journey; SVG diagrams explain actual commercial and privacy boundaries.
- Plan review: avoided a generic KPI dashboard and repeated cards because the task is a decision report. Numbering is reserved for delivery steps and sources.
- Responsive layout, keyboard focus, reduced-motion support and print styling.
- Three SVG assets are authored directly and include titles/descriptions. They are not generated raster diagrams.

## Skills

- Imagegen: /Users/erymuzuan/.codex/skills/.system/imagegen/SKILL.md (provided in conversation).
- Frontend design: /Users/erymuzuan/.claude/plugins/marketplaces/claude-plugins-official/plugins/frontend-design/skills/frontend-design/SKILL.md.
- MSBuild modernization: /Users/erymuzuan/.codex/plugins/cache/dotnet-agent-skills/dotnet-msbuild/0.1.11/skills/msbuild-modernization/SKILL.md.
- MSBuild review found SDK-style .NET 10 projects and central package management already present. No build files changed.

## Image generation

Mode: built-in imagegen tool.
Saved asset: assets/stay-journey.png
Original output: /Users/erymuzuan/.codex/generated_images/01a1724f-d29e-7841-a5ba-805c0092fdbf/exec-690bb927-5e7a-4c7e-8f9a-c91bb8bed3fa.png

Exact final prompt:

```text
Use case: stylized-concept
Asset type: editorial hero illustration for a Manotu travel booking integration research report
Primary request: an elegant architectural miniature of a Malaysian journey linking a boutique hotel, a tropical holiday home, and a city hotel along a winding road, illustrating accommodation discovery in a navigation app.
Style/medium: crafted paper and matte ceramic architectural diorama, sophisticated editorial illustration.
Composition/framing: wide landscape composition, three buildings joined by a flowing road, uncluttered pale blue backdrop, generous breathing room.
Lighting/mood: soft daylight, welcoming and calm.
Color palette: ocean blue, jade green, white, small golden sunlit accents.
Constraints: no text, no logos, no UI, no watermark, no brand marks. This is conceptual artwork, not real bookable inventory.
```

The result was visually inspected. It includes the three accommodation types and connecting road, with no text or logos. The render is more detailed than the requested paper/ceramic treatment but works as the editorial concept illustration. No real inventory is represented.

## Scope

Research and report only. No partner outreach, applications, live reservations, deployment or product code changes. Commercial terms and actual inventory access require partner confirmation.


## Validation

- Headless Chrome checked at 1440×1100 and 390×844.
- No page-level horizontal overflow, missing image assets, missing internal anchors, missing local links or JavaScript errors.
- Desktop hero, mobile hero and architecture diagram visually reviewed; corrected responsive article sizing and hero aspect ratio.
- Diagrams and wide comparison tables scroll within their containers on small screens.
- Report references 19 official provider sources. External source availability and partner intake can change after this research.
