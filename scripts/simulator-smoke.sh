#!/bin/bash
# Run against public, disposable archive fixtures in a separate simulator app sandbox.
set -euo pipefail
: "${1:?Usage: scripts/simulator-smoke.sh SIMULATOR_UDID}"
device=$1
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cavernseer-smoke.XXXXXX")
echo "Smoke evidence: $work"
bundle="io.github.lazarevtill.CavernSeerSmoke$(uuidgen | cut -c1-8)"
for f in CavernSeer CavernSeerTests CavernSeerUITests CavernSeer.xcodeproj docs; do
  rsync -a --exclude xcuserdata "$root/$f" "$work/"
done
sed -i '' "s/io\.github\.lazarevtill\.CavernSeer;/$bundle;/g" "$work/CavernSeer.xcodeproj/project.pbxproj"
cd "$work"
xcode=(xcodebuild -project CavernSeer.xcodeproj -scheme CavernSeer -configuration Debug
  -destination "platform=iOS Simulator,id=$device" -derivedDataPath "$work/build"
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO)
"${xcode[@]}" build-for-testing > build.log 2>&1
xcrun simctl bootstatus "$device" -b > boot.log 2>&1
xcrun simctl install "$device" build/Build/Products/Debug-iphonesimulator/CavernSeer.app
container=$(xcrun simctl get_app_container "$device" "$bundle" data)
mkdir -p "$container/Documents/scans"
fixture="$work/CavernSeerTests/TestData/green_v2.cavernseerscan"
cp "$fixture" "$container/Documents/scans/review_alpha.cavernseerscan"
cp "$fixture" "$container/Documents/scans/review_beta.cavernseerscan"
if ! "${xcode[@]}" -resultBundlePath "$work/full.xcresult" test-without-building > full.log 2>&1; then
  grep -E '(^Test Case .*failed|error:|^\*\* TEST)' full.log || true
  tail -20 full.log
  exit 1
fi
for test in testSeededScanRenderAndBackup testSeededFilteredDeleteAndRestore; do
  grep -E "Test Case .* $test\\]' passed" full.log
done
grep -E 'Executed [0-9]+ tests|TEST EXECUTE SUCCEEDED' full.log | tail -8
container=$(xcrun simctl get_app_container "$device" "$bundle" data)
cmp "$fixture" "$container/Documents/scans/review_alpha.cavernseerscan"
cmp "$fixture" "$container/Documents/scans/review_beta.cavernseerscan"
archive=$(find "$container/tmp" -name '*.zip' -print -quit)
if [[ -z "$archive" ]]; then
  # XCTest may dismiss the share sheet on exit and delete the temporary ZIP.
  echo "The system share sheet accepted the archive; use unit export checks for contents."
else
  cp "$archive" "$work/fixture-export.zip"
  unzip -qt "$work/fixture-export.zip"
  mkdir -p "$work/verified"
  unzip -q "$work/fixture-export.zip" -d "$work/verified"
  ( cd "$work/verified/CavernSeer-Backup"; shasum -a 256 -c SHA256SUMS; cmp "$fixture" ./*.cavernseerscan )
fi
