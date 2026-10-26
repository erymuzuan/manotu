---
name: facebook-post
description: >-
  Create and publish a post on the Manotu Facebook page: design the post as a board on the Manotu design
  canvas (Marketing page), capture real screenshots from the running app (iOS simulator, iPhone or the
  Samsung S24), get the owner's OK, then post it from the Facebook app on the S24 with the page identity,
  including the Google Play and TestFlight links. Use it whenever the user asks for a Facebook post,
  announcement, launch post, feature post or "share this on our page" for Manotu (e.g. "post the new route
  options on Facebook", "buat posting FB untuk jemputan kahwin", "add the store links to the page", "edit
  yesterday's post"), even if they only mention the design board, only the screenshots, or only Facebook.
  Not for Instagram/TikTok content or for the manotu.app website.
---

# Posting on the Manotu Facebook page

A post on the Manotu page is public the moment it goes out and is copied into feeds, so most of this skill
is about getting it right *before* the Share button: accurate claims, real screens, nobody's private data,
and the owner's explicit OK. The other half is the mechanics of driving the Facebook app over adb, which
are fiddly and are written down in `references/` so you don't have to rediscover them.

## The fixed pieces

| | |
|---|---|
| Design canvas | https://claude.ai/artifact/ACREFiVNz9gNyAbundwPWB, page `marketing` ("Marketing"), Facebook row starts at y = 5400 (boards `FbLaunch`, `FbMertua`, `FbKahwin`, …, 680 px wide, 80 px apart) |
| Board template | `assets/fb-post-board.dc.html` (Facebook card mockup: page header, caption, image grid, link card, reactions) |
| Posting device | Samsung S24, `adb -s RFCXA0LVBTE`, Facebook app `com.facebook.katana`, already switched to the **Manotu** page profile |
| Store links | read them fresh from `site/manotu/download/index.html` (today: Play `https://play.google.com/store/apps/details?id=my.manotu.app`, TestFlight `https://testflight.apple.com/join/vtNQMw4n`) |
| Content rules | the `mkN1` note on the Marketing page, `docs/privacy-promise.md`, and AGENTS.md (privacy rule, approved-dependency disclosure) |

## Workflow

### 1. Pin down the message
Work out the one feature or situation the post is about and who it speaks to (a driver, a family organizing a
kenduri, a festival trip…). Read the design page or docs for that feature so every claim is true *today*:

- If the feature is merged but not in a store build yet, say it is coming ("Akan tiba dalam kemas kini
  Android dan iPhone yang akan datang"), never "out now". Check `git log` / the last release tag if unsure.
- Privacy claims must match `docs/privacy-promise.md` word for word in meaning. Don't claim "no data at all"
  (the server gets public reports and anonymous speeds), and don't call the app "100% open source".
- Malay first, addressing the reader as "anda"; add a short English paragraph when the post announces a feature.
- No invented numbers, testimonials or reviews; no competitor names or logos; no real people's faces.

### 2. Capture real screens
Real app screens sell better than mockups and keep the post honest. Read `references/screenshots.md`.
The short version:

- Prefer **your own iOS simulator** with a temporary UI test (fixed demo location, `-AppleLanguages (ms)`),
  exported from the `.xcresult`. It is repeatable and never shows anyone's real location.
- The S24 and the iPhone are real phones: their screenshots show the owner's real position, recents and
  notifications. Only use them with a fake location / demo data, and check every pixel before using one.
- The iPhone is often lent to another Claude session. Ask the owner before using it and give it back.
- Never use screenshots that show personal chats (WhatsApp), contacts, Home/Work, or a real address.
- Delete the temporary UI test afterwards and never commit it; restore any file you appended to.

### 3. Design the board on the canvas
Load the Design artifact instructions by reading the canvas (`Artifact` read on the URL) before writing, then:

1. Upload the screenshots as canvas assets (`Artifact` publish with `asset: true`, `file_paths`) and use the
   returned `/_blob/<id>` URLs verbatim.
2. Copy `assets/fb-post-board.dc.html` to `project/Fb<Name>.dc.html`, fill in the caption and images, and set the
   board size to fit (680 wide; height grows with the caption).
3. Add a `boards` entry (page `marketing`, next free x in the Facebook row, a descriptive `title`) and its
   `order` slot in `project/canvas.json`; keep every other key. Publish both in one call.
4. Show the owner the board link and the caption text in chat. Mark store links as `[pautan Google Play]` /
   `[pautan TestFlight]` placeholders on the board if they're not final.

### 4. Get the owner's OK
Posting publishes to the public. Before touching Share, have an explicit "yes, post it" from the owner for
*this* post in this conversation (a design approval or an earlier post's approval doesn't carry over). If the
caption changes in a meaningful way after the OK, show it again.

### 5. Post from the S24
Read `references/facebook-s24.md`, then:

1. Check the phone is awake and unlocked (`dumpsys window | grep isKeyguardShowing`). If it is locked, ask the
   owner to unlock it; you cannot.
2. Push the images to `/sdcard/Pictures/Manotu/` and media-scan them so the gallery sees them.
3. Open the composer from the Facebook home (+ → Post) and confirm it shows **Manotu** as the author.
4. Type the caption with `scripts/fbtype.sh` (`t` text, `n` new line, `e` emoji search). Take a screenshot
   after each block and fix what autocorrect broke.
5. Remove the automatic link-preview card if images will be attached, then Gallery → Select multiple → pick
   the images in order → Next.
6. Post settings: audience Public, "Share to your profile" Off, AI label off for real app screenshots
   (on if any image is AI-generated). Then SHARE.
7. Decline "Boost Post" (paid) unless the owner asked for it.
8. Scroll to the new post and screenshot it to confirm the caption, links (blue) and images.

For edits to an existing post, use the post's ••• → Edit post; the same typing rules apply.

### 6. Report back
Tell the owner: the post is live (or what stopped it), the board link, the exact links included, any
differences from the mockup (emoji the keyboard substituted, words you rephrased to dodge autocorrect), and any
files you left on the phone (e.g. `/sdcard/Pictures/Manotu/`). Return borrowed devices.

## Things that went wrong before (and the fix)

- **adb types ASCII only.** Emoji come from the keyboard's emoji search (`e house`, `e parking`, `e clock`,
  `e play 3`, `e apple`, `e ring`); arrows "→" can't be typed, use ">".
- **SwiftKey autocorrect** rewrites `TestFlight`→`Testflight`, `iPhone`→`IPhone`, splits `salinannya`, and adds
  spaces before ":". Rephrase so the word ends a line or is followed by a URL, or fix with DPAD moves + delete.
- **Keyboard pop-ups** ("Are you enjoying SwiftKey?", feedback prompts) shift the emoji key: dismiss them first.
- **Coordinates are device-specific** (S24, 1080×2340, screenshots shown at 923×2000, ×1.17). Always take a
  screenshot and look before tapping; menus differ between posts (one tap landed on "Share partnership ad code").
- **The phone locks** between tasks; ask the owner to unlock rather than trying.
- **The app's "Your location"** on a real phone is the owner's home area. Fake the location or use the simulator.
