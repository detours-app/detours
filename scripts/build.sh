#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "Building Detour..."
swift build

echo "Updating app bundle..."
cp .build/arm64-apple-macosx/debug/Detour build/Detour.app/Contents/MacOS/Detour

echo "Touching app bundle to refresh Spotlight..."
touch build/Detour.app

echo "Done! App bundle updated at build/Detour.app"
