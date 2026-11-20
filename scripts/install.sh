#!/usr/bin/env bash
# Build, install to ~/Applications and (re)launch Runout Bar.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 0 ]]; then
  echo "Usage: scripts/install.sh" >&2
  exit 2
fi

scripts/build-app.sh
dest="$HOME/Applications/Runout Bar.app"
mkdir -p "$HOME/Applications"

# Quit a running copy before replacing it.
if pgrep -xq RunoutBar; then
  osascript -e 'tell application id "local.runout-bar" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do pgrep -xq RunoutBar || break; sleep 1; done
  pkill -x RunoutBar 2>/dev/null || true
fi
# Version 1.0 was called "Usage Bar": stop and remove that copy, so two bars never run at once.
pkill -x UsageBar 2>/dev/null || true
rm -rf "$HOME/Applications/Usage Bar.app"
rm -rf "$dest"
cp -R "build/Runout Bar.app" "$dest"
# Drop SSH and IDE-harness overrides so the launched app starts like a Finder launch.
env -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY \
  -u GEMINI_HOME -u AGY_ACP_FORCE_FILE_STORAGE -u ANTIGRAVITY_APP_DATA_DIR -u BROWSER \
  open "$dest"
echo "Installed $dest"
