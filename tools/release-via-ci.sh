#!/usr/bin/env bash
# Builds the release IPA on GitHub Actions and attaches it to a release.
#
# Why not build locally: the Mac here runs Xcode 27.2 / iOS 27.2 SDK, which is newer than
# the OS on the test device (27.0.1). The package built that way installs nowhere, while the
# same sources built on the CI runner (Xcode 27.1) install fine. The toolchain is the only
# difference between the two artefacts.
#
# Actions only runs free on public repositories, so a private repo is flipped public for the
# duration of the build and flipped back afterwards.
#
#     tools/release-via-ci.sh <tag> [asset-name]
#
set -euo pipefail

TAG="${1:?usage: release-via-ci.sh <tag> [asset-name]}"
ASSET_NAME="${2:-Wenku8-${TAG#v}-unsigned.ipa}"
REPO="jijijitian/light-novel-library_Wenku8_iOS"
WORKFLOW="iOS Build"
ARTIFACT="Wenku8-unsigned-ios27"

cd "$(dirname "$0")/.."

visibility="$(gh repo view "$REPO" --json visibility --jq '.visibility')"
restore_private=""
if [ "$visibility" = "PRIVATE" ]; then
  echo "==> making the repository public so Actions can run"
  gh repo edit "$REPO" --visibility public --accept-visibility-change-consequences >/dev/null
  restore_private=1
fi
trap 'if [ -n "$restore_private" ]; then echo "==> restoring private"; gh repo edit "$REPO" --visibility private --accept-visibility-change-consequences >/dev/null; fi' EXIT

echo "==> dispatching $WORKFLOW"
gh workflow run "$WORKFLOW" -R "$REPO" --ref master
sleep 10
run_id="$(gh run list -R "$REPO" --workflow "$WORKFLOW" --limit 1 --json databaseId --jq '.[0].databaseId')"
echo "    run $run_id"

echo "==> waiting for the build"
gh run watch "$run_id" -R "$REPO" --interval 20 --exit-status >/dev/null
test "$(gh run view "$run_id" -R "$REPO" --json conclusion --jq .conclusion)" = "success"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; if [ -n "$restore_private" ]; then echo "==> restoring private"; gh repo edit "$REPO" --visibility private --accept-visibility-change-consequences >/dev/null; fi' EXIT

echo "==> downloading the artefact"
gh run download "$run_id" -R "$REPO" -n "$ARTIFACT" -D "$tmp"
cp "$tmp/Wenku8-unsigned.ipa" "$tmp/$ASSET_NAME"
shasum -a 256 "$tmp/$ASSET_NAME" | sed "s|$tmp/||" > "$tmp/$ASSET_NAME.sha256"

echo "==> attaching to $TAG"
gh release upload "$TAG" "$tmp/$ASSET_NAME" "$tmp/$ASSET_NAME.sha256" --clobber -R "$REPO"

echo "==> verifying"
gh release download "$TAG" -R "$REPO" -p "$ASSET_NAME*" -D "$tmp/verify"
( cd "$tmp/verify" && shasum -a 256 -c "$ASSET_NAME.sha256" )
echo "done: $ASSET_NAME"
