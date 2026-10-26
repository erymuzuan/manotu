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
| Posting device | Samsung S24, `adb -s RFCXA0LVBTE` (another Android device is often attached, so always pass the serial or `export ANDROID_SERIAL=RFCXA0LVBTE`), Facebook app `com.facebook.katana`, already switched to the **Manotu** page profile |
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
- Never use screenshots that show personal chats (WhatsApp), contacts, Home/Work, or a real address. The
  Facebook feed and the Gallery picker also show other people's posts and the owner's personal photos: keep
  those screens out of anything you save or share.
- Delete the temporary UI test afterwards and never commit it; restore any file you appended to.

### 3. Design the board on the canvas
Load the Design artifact instructions by reading the canvas (`Artifact` read on the URL) before writing, then:

1. Upload the screenshots as canvas assets (`Artifact` publish with `asset: true`, `file_paths`) and use the
   returned `/_blob/<id>` URLs verbatim.
2. Facebook's grid crops tall phone screenshots: with 3–4 images each shows only its middle band. Pick
   the images knowing that (or crop them to the part that matters, or use 1–2 images), and check the real
   composer grid in step 5 before posting.
3. Copy `assets/fb-post-board.dc.html` to `project/Fb<Name>.dc.html`, fill in the caption and images, and set the
   board size to fit (680 wide; height grows with the caption).
4. Add a `boards` entry (page `marketing`, next free x in the Facebook row, a descriptive `title`) and its
   `order` slot in `project/canvas.json`; keep every other key. Re-read `canvas.json` right before
   publishing (other sessions edit the canvas too). Publish both in one call.
5. Show the owner the board link and the caption text in chat. Mark store links as `[pautan Google Play]` /
   `[pautan TestFlight]` placeholders on the board if they're not final.

### 4. Get the owner's OK
Posting publishes to the public. Before touching Share, have an explicit "yes, post it" from the owner for
*this* post in this conversation (a design approval or an earlier post's approval doesn't carry over). Edits to a
live post need the same: show the new text and get an OK before Save. If the caption changes in a meaningful
way after the OK, show it again.

### 5. Post from the S24
Read `references/facebook-s24.md`, then:

1. Check the phone is awake and unlocked (`dumpsys window | grep isKeyguardShowing`). If it is locked, ask the
   owner to unlock it; you cannot.
2. Push the images to `/sdcard/Pictures/Manotu/` and media-scan them so the gallery sees them.
3. Open the composer from the Facebook home (+ → Post) and confirm it shows **Manotu** as the author.
4. Type the caption with `scripts/fbtype.sh` (`t` text, `n` new line, `e` emoji search). After each block,
   read the text back with `uiautomator dump` (see the reference) rather than trusting a screenshot, and fix
   what autocorrect broke.
5. Remove the automatic link-preview card if images will be attached, then Gallery → Select multiple → pick
   the images in order → Next.
6. Post settings: audience Public, "Share to your profile" Off, AI label off for real app screenshots
   (on if any image is AI-generated). Then SHARE.
7. Decline "Boost Post" (paid) unless the owner asked for it.
8. Scroll to the new post and screenshot it to confirm the caption, links (blue) and images.

**Editing a live post:** the page timeline may open at the oldest posts, so the post can be *above* you. Use the
post's ••• → **Edit post** (4th item). Tapping the caption opens a full-screen "Add text" editor with the cursor
at the very end; put added paragraphs before the "Muat turun / Download" block and the hashtags. **Done** then
**Save** publishes the edit. To abandon an edit, use the editor's X → "Discard changes?" → DISCARD; Back does
not discard, it carries the text over to the Edit post screen.

### 6. Report back
Tell the owner: the post is live (or what stopped it), the board link, the exact links included, any
differences from the mockup (emoji the keyboard substituted, words you rephrased to dodge autocorrect), and any
files you left on the phone (e.g. `/sdcard/Pictures/Manotu/`). Return borrowed devices.

## Things that went wrong before (and the fix)

- **Check the live text before editing.** The owner or another session may have changed a post since it went out;
  build edits on what is there now, and mention differences you notice instead of reverting them.
- **adb types ASCII only.** Emoji come from the keyboard's emoji search (`e house`, `e parking`, `e clock`,
  `e play 3`, `e apple`, `e ring`); arrows "→" can't be typed, use ">".
- **Autocorrect** (SwiftKey is the default; check with `settings get secure default_input_method`) rewrites
  `TestFlight`→`Testflight`, `iPhone`→`IPhone` at a line start, `its`→`it's`, splits `salinannya`, swallows the
  space after brand words ("Androiddan") and adds spaces before ":". Write "Untuk iPhone", end a `t` chunk right
  after a brand word and start the next chunk with a space, and verify with `uiautomator dump`.
- **Fixing text by tapping is fragile:** the composer scrolls when the keyboard opens, `MOVE_HOME/END` work per
  wrapped line, and line ends carry a trailing space that throws off arrow counts. Prefer Ctrl+End
  (`input keycombination 113 123`) and `KEYCODE_FORWARD_DEL` from a cursor position you just confirmed.
- **Keyboard pop-ups** ("Are you enjoying SwiftKey?", feedback prompts) shift the emoji key: dismiss them first.
- **Coordinates are device-specific** (S24, 1080×2340, screenshots shown at 923×2000, ×1.17). Always take a
  screenshot and look before tapping; menus differ between posts (one tap landed on "Share partnership ad code").
- **The phone locks** between tasks; ask the owner to unlock rather than trying.
- **The app's "Your location"** on a real phone is the owner's home area. Fake the location or use the simulator.
