#!/bin/zsh
# Builds JAGBA for the GitHub repository this folder pushes to, publishes a
# release with JAGBA-mac.zip, and turns on the download page (docs/ on GitHub
# Pages). Needs the gh CLI, logged in. Run from a clean, pushed checkout.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
VERSION=$(sed -n 's/^VERSION=//p' build.sh)
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first."; exit 1; }

JAGBA_REPO="$REPO" ./build.sh
cp "build/JAGBA-$VERSION.zip" build/JAGBA-mac.zip
SHA=$(shasum -a 256 build/JAGBA-mac.zip | cut -d' ' -f1)
OWNER=${REPO%%/*}; NAME=${REPO#*/}

gh release create "v$VERSION" build/JAGBA-mac.zip --title "JAGBA $VERSION" --notes "$(cat <<NOTES
Save just the part you need: a clip, the audio, a transcript, or a whole post. For Mac (macOS 14 or newer, Apple Silicon and Intel).

**Install**
1. Download **JAGBA-mac.zip**, unzip it and drag **JAGBA** into Applications.
2. The first time, macOS says it can't verify JAGBA. Click **Done**, then open System Settings › Privacy & Security, click **Open Anyway** and **Open**. Only once.
3. Let JAGBA download its tools on first launch.

Step-by-step guide: https://$OWNER.github.io/$NAME/

SHA-256 of JAGBA-mac.zip: \`$SHA\`
NOTES
)"

# Serve docs/ as the download page (does nothing if it's already on).
gh api -X POST "repos/$REPO/pages" -f "source[branch]=main" -f "source[path]=/docs" >/dev/null 2>&1 || true
echo "Released v$VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
echo "Download page: https://$OWNER.github.io/$NAME/"
