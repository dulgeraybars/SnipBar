#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

rm -rf SnipBar.app
mkdir -p SnipBar.app/Contents/MacOS
swiftc -O -parse-as-library Sources/SnipBar/SnipBar.swift -o SnipBar.app/Contents/MacOS/SnipBar
cp Info.plist SnipBar.app/Contents/Info.plist

# With a fixed local self-signed identity (signing/, never committed) the app keeps its
# Screen Recording permission across rebuilds. Without it, fall back to ad-hoc signing,
# in which case macOS asks for the permission again after every rebuild.
KEYCHAIN="$PWD/signing/snipbar-signing.keychain-db"
if [[ -f "$KEYCHAIN" ]]; then
    security unlock-keychain -p snipbar-local "$KEYCHAIN"
    codesign --force --keychain "$KEYCHAIN" --sign "SnipBar Local Signing" SnipBar.app
else
    codesign --force --sign - SnipBar.app
fi
echo "Built SnipBar.app"
