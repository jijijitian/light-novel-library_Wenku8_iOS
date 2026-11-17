#!/usr/bin/env bash
# Generates Wenku8.xcodeproj from project.yml and, when a device is attached,
# installs and launches a debug build on it.
#
# This is the macOS-native replacement for the xtool flow described in earlier
# revisions of HANDOFF.md: the SwiftPM package stays authoritative for the core
# module and the tests, while Xcode builds the app slice from the same sources.
#
# Usage:
#   bash tools/bootstrap-xcodeproj.sh            # generate the project only
#   bash tools/bootstrap-xcodeproj.sh build      # generate + build for simulator
#   bash tools/bootstrap-xcodeproj.sh device     # generate + build + run on iPhone
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
ACTION="${1:-generate}"
TEAM="${DEVELOPMENT_TEAM:-C428Z585GG}"
BUNDLE_ID="${BUNDLE_ID:-org.mewx.wenku8.ios}"

# XcodeGen: prefer a system install, otherwise download the release binary once.
XCODEGEN="$(command -v xcodegen || true)"
if [[ -z "$XCODEGEN" ]]; then
  VENDOR="${ROOT}/.build-mac/tools/xcodegen/bin/xcodegen"
  if [[ ! -x "$VENDOR" ]]; then
    echo "==> fetching xcodegen"
    mkdir -p "${ROOT}/.build-mac/tools"
    curl -fsSL -o "${ROOT}/.build-mac/tools/xcodegen.zip" \
      https://github.com/yonaskolb/XcodeGen/releases/download/2.43.0/xcodegen.zip
    unzip -oq "${ROOT}/.build-mac/tools/xcodegen.zip" -d "${ROOT}/.build-mac/tools"
  fi
  XCODEGEN="$VENDOR"
fi

echo "==> generating Wenku8.xcodeproj"
"$XCODEGEN" generate --spec project.yml

if [[ "$ACTION" == "generate" ]]; then
  echo "done. open Wenku8.xcodeproj, or run: $0 device"
  exit 0
fi

# Derived data and caches are kept inside the repo so the script also works in
# sandboxes where ~/Library is not writable.
export TMPDIR="${ROOT}/.build-mac/tmp"
export CLANG_MODULE_CACHE_PATH="${ROOT}/.build-mac/clangcache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

if [[ "$ACTION" == "build" ]]; then
  echo "==> building for the iOS Simulator"
  xcodebuild -project Wenku8.xcodeproj -scheme Wenku8 \
    -configuration Debug -sdk iphonesimulator \
    -derivedDataPath "${ROOT}/.build-mac/dd" \
    CODE_SIGNING_ALLOWED=NO \
    build
  exit 0
fi

# --- device: pick the first connected iPhone -------------------------------
echo "==> looking for a connected iPhone"
DEVICE_JSON="$(mktemp)"
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1 || true
UDID="$(python3 - "$DEVICE_JSON" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for device in data.get("result", {}).get("devices", []):
    props = device.get("deviceProperties", {})
    if props.get("bootState") == "booted" or device.get("connectionProperties", {}).get("tunnelState") == "connected":
        print(device.get("identifier", ""))
        break
PY
)"
rm -f "$DEVICE_JSON"

if [[ -z "$UDID" ]]; then
  cat <<'MSG'
No iPhone found. Check that:
  - the phone is connected by cable and unlocked
  - "Trust This Computer" was accepted on the phone
  - Developer Mode is enabled (Settings > Privacy & Security > Developer Mode)
Then re-run: bash tools/bootstrap-xcodeproj.sh device
MSG
  exit 1
fi
echo "==> device $UDID"

echo "==> building for the device"
# CODE_SIGN_IDENTITY is passed explicitly: XcodeGen's generated project pins the
# legacy "iPhone Developer" identity for some targets, and when Xcode's account
# cache is cold it then reports "No Accounts" / "No signing certificate" even
# though a valid Apple Development identity is present in the keychain.
xcodebuild -project Wenku8.xcodeproj -scheme Wenku8 \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "${ROOT}/.build-mac/dd" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGN_STYLE=Automatic \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build

APP="${ROOT}/.build-mac/dd/Build/Products/Debug-iphoneos/Wenku8.app"
test -d "$APP" || { echo "built app not found at $APP"; exit 1; }

echo "==> installing and launching"
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"
