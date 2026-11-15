#!/bin/zsh
# Build Atoll in Release, sign it with a local self-signed identity, install it
# to /Applications and relaunch it.
#
# Why not ad-hoc: an ad-hoc signature changes with every build, so macOS treats
# each build as a new app and drops its Accessibility grant (and the menu-bar
# clearance, media keys and timer bridge stop working). A signature from a
# fixed certificate keeps the same designated requirement across builds, so
# permissions granted once survive rebuilds.
#
# Usage: scripts/install-local.sh ["Signing identity name or SHA-1"]
set -euo pipefail

IDENTITY="${1:-${ATOLL_SIGNING_IDENTITY:-Atoll Local Signing}}"
ROOT="${0:A:h:h}"
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Atoll.app"
LOG="$ROOT/build/xcodebuild.log"

mkdir -p "$ROOT/build"

if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
  echo "Signing identity \"$IDENTITY\" not found in the keychain." >&2
  exit 1
fi

echo "Building…"
if ! xcodebuild -project "$ROOT/DynamicIsland.xcodeproj" -scheme DynamicIsland \
    -configuration Release -derivedDataPath "$DERIVED" -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
    build > "$LOG" 2>&1; then
  grep -E " error:" "$LOG" | sort -u | head -20 >&2
  echo "Build failed; full log: $LOG" >&2
  exit 1
fi

echo "Signing with \"$IDENTITY\"…"
ENTITLEMENTS="$(mktemp -t atoll-entitlements).plist"
codesign -d --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null

# Nested code first, innermost out; the app last, with its own entitlements.
for nested in "$APP"/Contents/Frameworks/*.framework "$APP"/Contents/Resources/*.framework; do
  [[ -e "$nested" ]] || continue
  codesign --force --deep --timestamp=none -s "$IDENTITY" "$nested"
done
codesign --force --timestamp=none -s "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
rm -f "$ENTITLEMENTS"
codesign --verify --deep --strict "$APP"

echo "Installing…"
osascript -e 'quit app "Atoll"' 2>/dev/null || true
sleep 2
pkill -x Atoll 2>/dev/null || true
rm -rf /Applications/Atoll.app
ditto "$APP" /Applications/Atoll.app
open -a /Applications/Atoll.app

codesign -dr - /Applications/Atoll.app 2>&1 | tail -1
echo "Done."
