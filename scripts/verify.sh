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
# Every installed file: root-owned and not writable by others. sha256sum
# below only checks content.
lib_file=$(sed -nE 's/^[0-9a-f]{64}  lib\///p' "$manifest")
[ -n "$lib_file" ] || die "MANIFEST names no library"
for file in MANIFEST PIN "lib/$lib_file" lib/libfprint-2.so.2; do
    [ -e "$prefix/$file" ] || [ -L "$prefix/$file" ] || die "$DGL_PREFIX/$file is missing"
    check_secure_file "$prefix/$file"
done
# fprintd's library path points at lib/: anything else there would be
# loaded too. Allow exactly the two entries install.sh creates.
extra=$(find "$prefix" -mindepth 1 ! -path "$prefix/MANIFEST" ! -path "$prefix/PIN" ! -path "$prefix/lib" \
    ! -path "$prefix/lib/$lib_file" ! -path "$prefix/lib/libfprint-2.so.2" -print -quit)
[ -z "$extra" ] || die "unexpected file in $DGL_PREFIX: ${extra#"$prefix"/}"
(cd "$prefix" && grep -E '^[0-9a-f]{64}  ' "$manifest" | sha256sum --quiet -c -) ||
    die "installed files do not match MANIFEST"
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
