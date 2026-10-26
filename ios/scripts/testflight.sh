#!/bin/zsh
# Archive the Release build, export it for App Store Connect and upload it to TestFlight.
# Needs Config/asc.env (see Config/asc.env.example) and Config/Local.xcconfig (DEVELOPMENT_TEAM).
# Usage: scripts/testflight.sh [build-number]      (default: CURRENT_PROJECT_VERSION from project.yml)
set -euo pipefail
cd "${0:A:h}/.."
source Config/asc.env
: "${ASC_ISSUER_ID:?}" "${ASC_KEY_ID:?}" "${ASC_KEY_PATH:?}" "${ASC_TEAM_ID:?set ASC_TEAM_ID to the approved store team, STAFY COMPANY LIMITED (98KY9PMPX3)}"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
BUILD=${1:-}
# The store build has neither iCloud (App ID has no container yet) nor Google Drive backup (owner decision 2026-10-24).
# Override only for a non-store build: GIMANO_ICLOUD=YES / GIMANO_DRIVE=YES scripts/testflight.sh
GIMANO_ICLOUD=${GIMANO_ICLOUD:-NO}
GIMANO_DRIVE=${GIMANO_DRIVE:-NO}
OUT=${OUT:-build/testflight}
rm -rf "$OUT"; mkdir -p "$OUT"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

xcodegen generate
xcodebuild archive -project Gimano.xcodeproj -scheme Gimano -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/Gimano.xcarchive" \
  DEVELOPMENT_TEAM="$ASC_TEAM_ID" ${BUILD:+CURRENT_PROJECT_VERSION=$BUILD} GIMANO_ICLOUD="$GIMANO_ICLOUD" GIMANO_DRIVE="$GIMANO_DRIVE" "${AUTH[@]}"
INFO="$OUT/Gimano.xcarchive/Products/Applications/Gimano.app/Info.plist"
echo "iCloud=$(plutil -extract GimanoICloudEnabled raw -o - "$INFO") Drive=$(plutil -extract GimanoDriveEnabled raw -o - "$INFO")"
if [[ "$GIMANO_DRIVE" == NO ]] && grep -q googleusercontent "$INFO"; then
  echo "Refusing: GIMANO_DRIVE=NO but a Google OAuth client is in Info.plist." >&2; exit 1
fi
# AGENTS.md (owner reconfirmed 26 Oct 2026): Manotu TestFlight/App Store uses STAFY COMPANY LIMITED, team 98KY9PMPX3.
APPROVED_TEAM_ID=98KY9PMPX3
APP="$OUT/Gimano.xcarchive/Products/Applications/Gimano.app"
TEAM_NAME=$(security cms -D -i "$APP/embedded.mobileprovision" | plutil -extract TeamName raw -)
TEAM_ID=$(security cms -D -i "$APP/embedded.mobileprovision" | plutil -extract TeamIdentifier.0 raw -)
echo "Signed by team: $TEAM_NAME ($TEAM_ID)"
if [[ "$ASC_TEAM_ID" != "$APPROVED_TEAM_ID" || "$TEAM_ID" != "$APPROVED_TEAM_ID" ]]; then
  echo "Refusing: archive is not signed by the approved store team $APPROVED_TEAM_ID (got $TEAM_NAME $TEAM_ID)." >&2; exit 1
fi
xcodebuild -exportArchive -archivePath "$OUT/Gimano.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist Config/ExportOptions-AppStore.plist "${AUTH[@]}"
xcrun altool --upload-app -f "$OUT/export/Gimano.ipa" -t ios \
  --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH"
echo "Uploaded build ${BUILD:-from project.yml}. It appears in TestFlight after processing (~10-30 min)."
