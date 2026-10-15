#!/usr/bin/env bash
# Hardware test on a real laptop with the 538d sensor. Interactive: asks
# before installing, asks you to touch the sensor, and offers to uninstall at
# the end. Never runs in CI.
#
#   DGL_HARDWARE=1 tests/hardware.sh
#
# Run scripts/fetch.sh and scripts/build.sh first, as your normal user.

set -euo pipefail
cd "$(dirname "$0")/.."

[ "${DGL_HARDWARE:-}" = 1 ] || { echo "set DGL_HARDWARE=1 to run (uses the real sensor and sudo)" >&2; exit 2; }
[ "$(id -u)" != 0 ] || { echo "run as your normal user; it uses sudo where needed" >&2; exit 2; }

ask() {
    local answer
    read -r -p "$1 [y/N] " answer
    [[ $answer == [yY]* ]]
}

step() { printf '\n### %s\n' "$*"; }

step "1/5 Probe: does the driver accept this sensor? (nothing is installed)"
scripts/probe.sh

step "2/5 Install"
ask "Install to /opt/dell-goodix-538d and point fprintd at it?" || exit 0
scripts/install.sh
scripts/verify.sh
fprintd-list "$USER"

step "3/5 Enroll (touch the sensor repeatedly when asked)"
fprintd-enroll -f right-index-finger "$USER"

step "4/5 Verify: touch with the SAME finger, then with a DIFFERENT finger"
fprintd-verify -f right-index-finger "$USER" || true
fprintd-verify -f right-index-finger "$USER" || true
ask "Was the same finger accepted and the different finger rejected?" || {
    echo "Matching is not reliable on this unit; consider scripts/uninstall.sh." >&2
    exit 1
}

step "5/5 Lock screen"
echo "Lock the screen (Super+L) and unlock with your finger. Your password still works."
ask "Did fingerprint unlock work?" || echo "See the README section on login and unlock."

if ask "Uninstall now (this test is done)?"; then
    fprintd-delete "$USER" || true
    scripts/uninstall.sh
    fprintd-list "$USER" || true
fi
echo "Hardware test finished."
