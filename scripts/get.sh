#!/usr/bin/env bash
# Download the latest released "Runout Bar.app", check it and install it. No Swift toolchain needed.
#
#   curl -fsSL https://raw.githubusercontent.com/RobinVivant/runout-bar/main/scripts/get.sh | bash
#
# RUNOUT_BAR_DIR      where the app goes (default: ~/Applications)
# RUNOUT_BAR_VERSION  the release to install, such as 1.0.0 (default: the latest)
# RUNOUT_BAR_NO_OPEN  set to 1 to install without quitting a running copy or opening the new one
set -euo pipefail

repo="https://github.com/RobinVivant/runout-bar"
work=""  # the download folder; global, so the exit trap can still read it after main returns
trap '[[ -z "$work" ]] || rm -rf "$work"' EXIT

fail() {
  echo "Runout Bar install: $1" >&2
  exit 1
}

# The whole script runs from this function, so a download that stops halfway runs nothing.
main() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "this app runs on macOS only."
  [[ "$(uname -m)" == "arm64" ]] || fail "the release is built for Apple silicon. On an Intel Mac, build from source."
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [[ "$major" -ge 15 ]] || fail "macOS 15 or later is required (this Mac runs $(sw_vers -productVersion))."

  local version="${RUNOUT_BAR_VERSION:-}"
  if [[ -z "$version" ]]; then
    # The "latest" page redirects to the newest tag; this needs no API call and no rate limit.
    local latest
    latest="$(curl -fsSI -o /dev/null -w '%{redirect_url}' "$repo/releases/latest")"
    version="${latest##*/v}"
    [[ "$latest" == */releases/tag/v* && -n "$version" ]] || fail "could not find the latest release at $repo/releases."
  fi

  local zip="Runout-Bar-$version-arm64.zip"
  local dir="${RUNOUT_BAR_DIR:-$HOME/Applications}"
  local dest="$dir/Runout Bar.app"
  work="$(mktemp -d)"

  echo "Downloading Runout Bar $version"
  curl -fsSL -o "$work/$zip" "$repo/releases/download/v$version/$zip" ||
    fail "could not download $zip from release v$version."
  curl -fsSL -o "$work/$zip.sha256" "$repo/releases/download/v$version/$zip.sha256" ||
    fail "could not download the checksum of release v$version."
  (cd "$work" && shasum -a 256 -c "$zip.sha256" >/dev/null) || fail "the download does not match its checksum."

  ditto -x -k "$work/$zip" "$work"
  codesign --verify --strict "$work/Runout Bar.app" || fail "the app's signature is not valid."

  if [[ "${RUNOUT_BAR_NO_OPEN:-}" != "1" ]] && pgrep -xq RunoutBar; then
    osascript -e 'tell application id "local.runout-bar" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      pgrep -xq RunoutBar || break
      sleep 1
    done
    pkill -x RunoutBar 2>/dev/null || true
  fi

  # Version 1.0 was called "Usage Bar": stop and remove that copy, so two bars never run at once.
  if [[ "${RUNOUT_BAR_NO_OPEN:-}" != "1" ]]; then
    pkill -x UsageBar 2>/dev/null || true
  fi
  rm -rf "$dir/Usage Bar.app"

  mkdir -p "$dir"
  rm -rf "$dest"
  ditto "$work/Runout Bar.app" "$dest"
  echo "Installed $dest"
  if [[ "${RUNOUT_BAR_NO_OPEN:-}" != "1" ]]; then
    env -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY \
      -u GEMINI_HOME -u AGY_ACP_FORCE_FILE_STORAGE -u ANTIGRAVITY_APP_DATA_DIR -u BROWSER \
      open "$dest"
  fi
}

main "$@"
