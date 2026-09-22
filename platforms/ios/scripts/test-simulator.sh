#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
DEVICE_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); phones=[x["udid"] for runtime,items in d["devices"].items() if "iOS" in runtime for x in items if x["name"].startswith("iPhone")]; assert phones,"No iPhone simulator available"; print(phones[0])')
xcodebuild -project platforms/ios/RIMES.xcodeproj -scheme RIMES -destination "platform=iOS Simulator,id=$DEVICE_ID" -derivedDataPath platforms/ios/build/DerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
