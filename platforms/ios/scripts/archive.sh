#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"
python3 platforms/ios/scripts/verify.py --distribution
: "${RIMES_DEVELOPMENT_TEAM:?Set the verified Apple Developer team ID}"
xcodebuild -project platforms/ios/RIMES.xcodeproj -scheme RIMES -configuration Release -destination 'generic/platform=iOS' -archivePath platforms/ios/build/RIMES.xcarchive DEVELOPMENT_TEAM="$RIMES_DEVELOPMENT_TEAM" archive
# Upload only after reviewing the archive and App Store Connect record in Xcode Organizer.
