#!/usr/bin/env bash
# Export the PNG screenshots attached to an .xcresult bundle, named by their XCTAttachment name.
# Usage: export_shots.sh <bundle.xcresult> <out-dir>
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
bundle="$1"; out="$2"
raw="$out/.raw"; rm -rf "$raw"; mkdir -p "$raw" "$out"
xcrun xcresulttool export attachments --path "$bundle" --output-path "$raw" >/dev/null
python3 -I - "$raw" "$out" <<'PY'
import json, shutil, sys, os, re
raw, out = sys.argv[1], sys.argv[2]
for test in json.load(open(os.path.join(raw, "manifest.json"))):
    for a in test["attachments"]:
        f = a["exportedFileName"]
        if not f.endswith(".png"):
            continue
        name = re.sub(r"_\d+_[0-9A-F-]{36}\.png$", "", a.get("suggestedHumanReadableName", f)) + ".png"
        shutil.copy(os.path.join(raw, f), os.path.join(out, name))
        print(os.path.join(out, name))
PY
