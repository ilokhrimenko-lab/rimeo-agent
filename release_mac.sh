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

# 1. Get latest build number from GitHub tags (not releases — failed builds don't create releases)
echo "==> Fetching latest build number from GitHub..."
LATEST_TAG=$(git ls-remote --tags origin \
  | grep -oE '(win-|mac-)?v1\.0-build[0-9]+$' \
  | grep -oE '[0-9]+$' \
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
# Stage build_info.py AND every modified tracked file (workflow, Swift sources,
# etc.) so a release never ships stale code. `git add -u` only touches files git
# already tracks — untracked junk (._* AppleDouble, build artifacts) is ignored.
#
# `-c core.fileMode=false` is a per-command override (NOT a persisted config
# change): the SanDisk volume flips the executable bit on most files, which would
# otherwise make `git add -u` sweep ~80 mode-only "changes" into every release
# commit. With fileMode off, only real content changes get staged.
COMMIT_MSG="Build ${NEXT}${MESSAGE:+: }${MESSAGE}"
GIT_NOMODE="git -c core.fileMode=false"
$GIT_NOMODE add build_info.py
$GIT_NOMODE add -u
STAGED="$($GIT_NOMODE diff --cached --name-only)"
if [ -z "$STAGED" ]; then
  echo "ERROR: nothing staged — no real code changes detected. Aborting release."
  exit 1
fi
echo "==> Staged for release:"
printf '%s\n' "$STAGED" | sed 's/^/    /'
$GIT_NOMODE commit -m "$COMMIT_MSG"
echo "==> Committed: $COMMIT_MSG"

# 4. Tag and push
git tag "$TAG_NAME"
git push origin main
git push origin "$TAG_NAME"

echo ""
echo "✓ Pushed $TAG_NAME — macOS CI is building."
echo ""
gh run watch
