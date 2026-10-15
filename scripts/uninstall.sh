#!/usr/bin/env bash
# Remove everything scripts/install.sh added and put fprintd back on Ubuntu's
# own libfprint. Safe to run more than once.
#
# Usage: scripts/uninstall.sh

# shellcheck source=lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

prefix=$(rootpath "$DGL_PREFIX")
dropin=$(rootpath "$DGL_DROPIN")
calib=$(rootpath "$DGL_CALIB")
changed=

if [ -f "$dropin" ]; then
    dropin_is_ours "$dropin" || die "$DGL_DROPIN was not written by this project; not touching it"
    info "Removing $DGL_DROPIN"
    as_root rm -f "$dropin"
    as_root rmdir "$(dirname "$dropin")" 2>/dev/null || true
    # Reload now, so fprintd cannot be started with a path that is about to
    # disappear.
    as_root "$SYSTEMCTL" daemon-reload
    changed=1
fi

if [ -e "$prefix" ]; then
    [ -f "$prefix/MANIFEST" ] || die "$DGL_PREFIX was not installed by this project; not touching it"
    info "Removing $DGL_PREFIX"
    as_root rm -rf "$prefix"
    changed=1
fi
for leftover in "$prefix.new" "$prefix.old"; do
    if [ -e "$leftover" ]; then
        [ -f "$leftover/MANIFEST" ] || die "$leftover was not created by this project; not touching it"
        as_root rm -rf "$leftover"
        changed=1
    fi
done

if as_root test -f "$calib"; then
    info "Removing the sensor calibration file"
    as_root rm -f "$calib"
    changed=1
fi

if [ -n "$changed" ]; then
    as_root "$SYSTEMCTL" daemon-reload
    as_root "$SYSTEMCTL" reset-failed fprintd.service 2>/dev/null || true
    as_root "$SYSTEMCTL" try-restart fprintd.service 2>/dev/null || true
    info "Uninstalled. fprintd uses Ubuntu's libfprint again."
    info "Fingerprints enrolled with this driver no longer work; delete them with: fprintd-delete \"\$USER\""
else
    info "Nothing to uninstall."
fi
