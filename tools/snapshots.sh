#!/bin/zsh
# Renders every screen to build/screens/*.png using sample data.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
ls Sources/*.swift | grep -v JagbaApp.swift > build/snap-sources.txt
cp tools/snapshots.swift build/main.swift  # top-level code must live in main.swift
swiftc -swift-version 5 -target arm64-apple-macos14.0 $(cat build/snap-sources.txt) build/main.swift -o build/snapshots
build/snapshots build/screens tools/demo-thumb.png
