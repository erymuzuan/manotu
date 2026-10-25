#!/bin/bash
# Run CarPlay regression tests without changing device profiles or signing settings.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <iOS-simulator-UDID>" >&2
  echo "List devices with: xcrun simctl list devices available" >&2
  exit 2
fi
cd "$(dirname "$0")/.."
exec xcodebuild -project Gimano.xcodeproj -scheme Gimano \
  -destination "platform=iOS Simulator,id=$1" \
  -only-testing:GimanoTests/CarPlayTests \
  GIMANO_ICLOUD=NO GIMANO_DRIVE=NO CODE_SIGNING_ALLOWED=NO test
