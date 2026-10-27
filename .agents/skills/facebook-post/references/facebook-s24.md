# Driving Facebook on the S24 over adb

Device `RFCXA0LVBTE`, 1080×2340. Screenshots from `adb exec-out screencap -p` are shown at 923×2000, so multiply
what you see by 1.17 to get tap coordinates. The numbers below worked on 26 Oct 2026; treat them as starting
points and confirm with a screenshot every time.

```bash
export ANDROID_SERIAL=RFCXA0LVBTE
source .claude/skills/facebook-post/scripts/fbtype.sh       # t / n / e helpers
adb exec-out screencap -p > "$SCRATCH/s24/x.png"            # then Read the file
```

## Before anything
- More than one Android device may be attached: keep `ANDROID_SERIAL=RFCXA0LVBTE` set (a bare `adb` fails).
- The home feed shifts as it loads; a tap meant for `+` can land on Reels or the side menu. Re-screenshot first.
- `adb shell dumpsys window | grep -m1 isKeyguardShowing` → `true` means locked: ask the owner to unlock.
- `adb shell monkey -p com.facebook.katana -c android.intent.category.LAUNCHER 1` opens Facebook.
- The app should already act as the **Manotu** page (composer shows "Manotu Manotu"). If it shows the owner's
  personal name, stop and ask; don't switch profiles yourself.

## New post
1. Home → `+` (top bar, ≈ 780,160) → **Post** (≈ 775,285).
2. Tap the text area (≈ 460,660) and type with `t` / `n` / `e`.
3. A link in the text makes Facebook add a preview card; tap its ✕ (≈ 1032,1973, bottom of the screen) when you
   will attach images.
4. **Gallery** (bottom card) → **Select multiple** (≈ 830,323) → tap images in the order they should appear →
   **Next** (≈ 965,2090). Thumbnails along the bottom confirm the order.
5. **Next** (top right) → Post settings: Post audience Public, Who can comment Public, Share to your profile Off,
   Add AI label off for real screenshots → **SHARE** (≈ 937,176).
6. "Increase your reach / Boost Post" sheet → **Not Now** (≈ 793,2007).

## Edit an existing post
Page timeline: tap the Manotu avatar left of "What's on your mind?" on the home feed (the top bar may be hidden;
scroll up a little to show it). The timeline can open at the oldest posts, so scroll *up* to find recent ones.
••• on the post header (≈ 1027) → **Edit post** (4th: Pin post, Save post, View edit history, Edit post).
Tap the caption: a full-screen "Add text" editor opens with the cursor at the end. **Done** returns to Edit post,
**Save** publishes. To abandon: X → "Discard changes?" → DISCARD (Back keeps the typed text).
Adding photos: ••• in the editor → add media → Gallery, same as above.

## Page profile settings
- Links: page → Edit (pencil) → Links → add website URL + title.
- Action button: page → ••• → Edit action buttons → Edit buttons → e.g. "Learn more" with a website. Two buttons max.

## Reading the text back
`adb shell uiautomator dump /sdcard/ui.xml && adb exec-out cat /sdcard/ui.xml` gives the editor's exact text
(the `text=` of the EditText). Use it to check what autocorrect did; screenshots miss doubled spaces and
swallowed ones.

## Typing
- `t "text with spaces"` (spaces become `%s`; apostrophes and `&` are fine, avoid `"`, `$`, backticks and `\`).
- `n` presses Enter. `e <word> [slot]` opens the emoji panel, searches, taps result `slot` (default 1), returns to letters.
- Emoji panel search box ≈ 480,1362 with the keyboard showing; results row y ≈ 1362, slots 112 px apart from x 168.
- Fix a word: tap just after it, `adb shell input keyevent KEYCODE_DPAD_LEFT` × n, `KEYCODE_DEL`.
- Clear a line: tap it, `KEYCODE_MOVE_END`, then `KEYCODE_DEL` × its length.
- `KEYCODE_BACK` hides the keyboard but moves focus to the composer's X: a stray Enter afterwards opens the
  discard sheet.
- Ctrl+End: `adb shell input keycombination 113 123`. `KEYCODE_FORWARD_DEL` deletes to the right.

## Leave it tidy
Push files only under `/sdcard/Pictures/Manotu/`. Don't open or screenshot personal chats or notifications.
Press Home when finished.
