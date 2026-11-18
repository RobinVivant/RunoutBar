#!/usr/bin/env bash
# Download the latest released "Usage Bar.app", check it and install it. No Swift toolchain needed.
#
#   curl -fsSL https://raw.githubusercontent.com/RobinVivant/usage-bar/main/scripts/get.sh | bash
#
# USAGE_BAR_DIR      where the app goes (default: ~/Applications)
# USAGE_BAR_VERSION  the release to install, such as 1.0.0 (default: the latest)
# USAGE_BAR_NO_OPEN  set to 1 to install without quitting a running copy or opening the new one
set -euo pipefail

repo="https://github.com/RobinVivant/usage-bar"
work=""  # the download folder; global, so the exit trap can still read it after main returns
trap '[[ -z "$work" ]] || rm -rf "$work"' EXIT

fail() {
  echo "Usage Bar install: $1" >&2
  exit 1
}

# The whole script runs from this function, so a download that stops halfway runs nothing.
main() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "this app runs on macOS only."
  [[ "$(uname -m)" == "arm64" ]] || fail "the release is built for Apple silicon. On an Intel Mac, build from source."
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [[ "$major" -ge 15 ]] || fail "macOS 15 or later is required (this Mac runs $(sw_vers -productVersion))."

  local version="${USAGE_BAR_VERSION:-}"
  if [[ -z "$version" ]]; then
    # The "latest" page redirects to the newest tag; this needs no API call and no rate limit.
    local latest
    latest="$(curl -fsSI -o /dev/null -w '%{redirect_url}' "$repo/releases/latest")"
    version="${latest##*/v}"
    [[ "$latest" == */releases/tag/v* && -n "$version" ]] || fail "could not find the latest release at $repo/releases."
  fi

  local zip="Usage-Bar-$version-arm64.zip"
  local dir="${USAGE_BAR_DIR:-$HOME/Applications}"
  local dest="$dir/Usage Bar.app"
  work="$(mktemp -d)"

  echo "Downloading Usage Bar $version"
  curl -fsSL -o "$work/$zip" "$repo/releases/download/v$version/$zip" ||
    fail "could not download $zip from release v$version."
  curl -fsSL -o "$work/$zip.sha256" "$repo/releases/download/v$version/$zip.sha256" ||
    fail "could not download the checksum of release v$version."
  (cd "$work" && shasum -a 256 -c "$zip.sha256" >/dev/null) || fail "the download does not match its checksum."

  ditto -x -k "$work/$zip" "$work"
  codesign --verify --strict "$work/Usage Bar.app" || fail "the app's signature is not valid."

  if [[ "${USAGE_BAR_NO_OPEN:-}" != "1" ]] && pgrep -xq UsageBar; then
    osascript -e 'tell application id "local.usage-bar" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      pgrep -xq UsageBar || break
      sleep 1
    done
    pkill -x UsageBar 2>/dev/null || true
  fi

  mkdir -p "$dir"
  rm -rf "$dest"
  ditto "$work/Usage Bar.app" "$dest"
  echo "Installed $dest"
  if [[ "${USAGE_BAR_NO_OPEN:-}" != "1" ]]; then
    open "$dest"
  fi
}

main "$@"
