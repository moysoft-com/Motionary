#!/bin/bash
# Reproducible local release checks. No signing, upload or distribution.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 1 ]]; then
    echo 'Usage: scripts/verify-release.sh "platform=iOS Simulator,name=iPhone 17"' >&2
    exit 2
fi
result_root="build/release-verification/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$result_root"
plutil -lint Motionary/Info.plist Motionary/PrivacyInfo.xcprivacy
xcodebuild test -project Motionary.xcodeproj -scheme Motionary \
    -configuration Debug -destination "$1" -parallel-testing-enabled NO \
    -derivedDataPath "$result_root/DerivedData" \
    -resultBundlePath "$result_root/Tests.xcresult" \
    CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
xcodebuild build -project Motionary.xcodeproj -scheme Motionary \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$result_root/DerivedData" \
    CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
