#!/bin/bash
# Push a new macOS-only release to GitHub.
# Reads the latest build number from GitHub, increments it, updates build_info.py,
# commits, tags (mac-v1.0-buildNNN), and pushes — triggering only the macOS CI job.
#
# Usage: ./release_mac.sh [message]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

MESSAGE="${1:-}"

# 1. Get latest build number from GitHub (check both tag formats)
echo "==> Fetching latest build number from GitHub..."
LATEST_TAG=$(gh release list --limit 20 --json tagName --jq '.[].tagName' \
  | grep -E '^(mac-)?v1\.0-build[0-9]+$' \
  | sed 's/^mac-//' \
  | sed -n 's/^v1\.0-build\([0-9][0-9]*\)$/\1/p' \
  | sort -n | tail -1)

if [ -z "$LATEST_TAG" ]; then
  echo "ERROR: could not determine latest build number from GitHub"
  exit 1
fi

NEXT=$((LATEST_TAG + 1))
TAG_NAME="mac-v1.0-build${NEXT}"
echo "    latest: build${LATEST_TAG}  →  new: build${NEXT} (${TAG_NAME})"

# 2. Update build_info.py
printf 'VERSION = "1.0"\nBUILD_NUMBER = "%s"\nRELEASE_TAG = "%s"\n' \
  "$NEXT" "$TAG_NAME" > build_info.py
echo "==> build_info.py updated"

# 3. Commit
COMMIT_MSG="Build ${NEXT}${MESSAGE:+: }${MESSAGE}"
git add build_info.py
git commit -m "$COMMIT_MSG"
echo "==> Committed: $COMMIT_MSG"

# 4. Tag and push
git tag "$TAG_NAME"
git push origin main
git push origin "$TAG_NAME"

echo ""
echo "✓ Pushed $TAG_NAME — macOS CI is building."
echo ""
gh run watch
