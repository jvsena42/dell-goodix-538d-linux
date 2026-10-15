#!/usr/bin/env bash
# Check an existing install: files match MANIFEST and are root-owned, the
# drop-in is intact, the installed fprintd still finds every function it
# needs (an fprintd upgrade could break this), and fprintd loads our library.
#
# Usage: scripts/verify.sh

# shellcheck source=lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

prefix=$(rootpath "$DGL_PREFIX")
dropin=$(rootpath "$DGL_DROPIN")
manifest=$prefix/MANIFEST

[ -f "$manifest" ] || die "not installed ($DGL_PREFIX/MANIFEST is missing)"
check_secure_path "$prefix/lib"
(cd "$prefix" && grep -E '^[0-9a-f]{64}  ' "$manifest" | sha256sum --quiet -c -) ||
    die "installed files do not match MANIFEST"
lib_file=$(sed -nE 's/^[0-9a-f]{64}  lib\///p' "$manifest")
[ "$(readlink "$prefix/lib/libfprint-2.so.2")" = "$lib_file" ] ||
    die "$DGL_PREFIX/lib/libfprint-2.so.2 does not point at $lib_file"
info "Files match MANIFEST"

[ -f "$dropin" ] || die "$DGL_DROPIN is missing"
[ "$(cat "$dropin")" = "$(dropin_content)" ] || die "$DGL_DROPIN has been changed"
check_secure_path "$(dirname "$dropin")"
info "Drop-in is intact"

check_symbols "$prefix/lib/libfprint-2.so.2" "$(rootpath /usr/libexec/fprintd)"
installed_for=$(sed -n 's/^fprintd_version=//p' "$manifest")
if [ "$installed_for" != "$(fprintd_version)" ]; then
    info "Note: fprintd changed from $installed_for to $(fprintd_version) since install; its symbols still match"
fi
info "fprintd finds every libfprint function it needs"

as_root "$SYSTEMCTL" start fprintd.service
fprintd_uses_ours || die "fprintd is running without $DGL_PREFIX/lib"
info "fprintd is using $DGL_PREFIX/lib"
