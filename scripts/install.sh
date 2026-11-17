#!/usr/bin/env bash
# Build, install to ~/Applications and (re)launch Usage Bar.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 0 ]]; then
  echo "Usage: scripts/install.sh" >&2
  exit 2
fi

scripts/build-app.sh
dest="$HOME/Applications/Usage Bar.app"
mkdir -p "$HOME/Applications"

# Quit a running copy before replacing it.
if pgrep -xq UsageBar; then
  osascript -e 'tell application id "local.usage-bar" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do pgrep -xq UsageBar || break; sleep 1; done
  pkill -x UsageBar 2>/dev/null || true
fi
rm -rf "$dest"
cp -R "build/Usage Bar.app" "$dest"
open "$dest"
echo "Installed $dest"
