# Source me: typing helpers for the Facebook app on the S24 (SwiftKey keyboard).
# t "text"      type ASCII text (spaces become %s)
# n             new line
# e word [N]    insert the Nth result of a keyboard emoji search (default 1)
export ANDROID_SERIAL="${ANDROID_SERIAL:-RFCXA0LVBTE}"
t() { local s="${1// /%s}"; adb shell "input text '$s'"; }
n() { adb shell input keyevent KEYCODE_ENTER; }
e() {
  adb shell input tap 161 2135; sleep 1.5          # emoji key (keyboard without pop-up banners)
  adb shell input tap 480 1362; sleep 1            # emoji search box
  adb shell input text "$1"; sleep 2
  adb shell input tap $((168 + (${2:-1} - 1) * 112)) 1362; sleep 1
  adb shell input tap 55 1361; sleep 1             # back from search
  adb shell input tap 70 2150; sleep 1             # "abc": back to letters
}
