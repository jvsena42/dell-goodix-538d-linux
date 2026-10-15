#!/usr/bin/env bash
# Install the library built by scripts/build.sh to /opt/dell-goodix-538d and
# point fprintd at it with a systemd drop-in. No Ubuntu file is overwritten.
# If fprintd does not come up on the new library, everything is rolled back.
#
# Usage: scripts/install.sh [--force]
#
# --force skips the requirement that scripts/probe.sh passed (CI uses it,
# because there is no sensor there).

# shellcheck source=lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

force=
case ${1:-} in
    "") ;;
    --force) force=1 ;;
    *) die "usage: $0 [--force]" ;;
esac


load_pin "$DGL_PIN_FILE"
build=$DGL_WORK_DIR/build
built_lib=$(readlink -f "$build/libfprint/libfprint-2.so.2" 2>/dev/null) ||
    die "no build found; run scripts/build.sh first"
[ -f "$built_lib" ] || die "no build found; run scripts/build.sh first"
lib_name=$(basename "$built_lib")
[[ $lib_name =~ ^libfprint-2\.so\.2\.[0-9.]+$ ]] || die "unexpected library file name: $lib_name"

check_private_file "$built_lib"
lib_sum=$(sha256sum "$built_lib" | cut -d' ' -f1)

# The build must come from the pinned commit, and the probe must have passed
# on this exact library (not an earlier build).
[ "$(build_stamp "$build")" = "$FORK_SHA $lib_sum" ] ||
    die "$build was not built from the pinned commit (or changed since); run scripts/build.sh"
if [ -z "$force" ]; then
    [ "$(cat "$DGL_WORK_DIR/probe.result" 2>/dev/null)" = "pass $FORK_SHA $lib_sum" ] ||
        die "scripts/probe.sh has not passed for this build; run it first"
fi

check_symbols "$built_lib" "$(rootpath /usr/libexec/fprintd)"

prefix=$(rootpath "$DGL_PREFIX")
dropin=$(rootpath "$DGL_DROPIN")
dropin_dir=$(dirname "$dropin")
staging=$prefix.new
previous=$prefix.old

check_secure_path "$(dirname "$prefix")"
check_secure_path "$(dirname "$dropin_dir")"
if [ -e "$prefix" ] && [ ! -f "$prefix/MANIFEST" ]; then
    die "$DGL_PREFIX exists but was not installed by this project; not touching it"
fi
if [ -e "$dropin" ] && ! dropin_is_ours "$dropin"; then
    die "$DGL_DROPIN exists but was not written by this project; not touching it"
fi

tmp=$(mktemp -d)
had_dropin=
if [ -f "$dropin" ]; then
    had_dropin=1
    cp "$dropin" "$tmp/dropin.previous"
fi

# Undo everything from step 2 on. Every command may fail without stopping
# the rest, so a half-finished rollback cannot happen.
rollback() {
    info "Rolling back"
    if [ -n "$had_dropin" ]; then
        as_root install -m 0644 -o "$SECURE_UID" -g "$SECURE_GID" "$tmp/dropin.previous" "$dropin" || true
    else
        as_root rm -f "$dropin" || true
        as_root rmdir "$dropin_dir" 2>/dev/null || true
    fi
    if [ -e "$previous" ]; then
        as_root rm -rf "$prefix" || true
        as_root mv "$previous" "$prefix" || true
    elif [ -n "$swapped" ]; then
        as_root rm -rf "$prefix" || true
    fi
    as_root "$SYSTEMCTL" daemon-reload || true
    as_root "$SYSTEMCTL" reset-failed fprintd.service 2>/dev/null || true
    as_root "$SYSTEMCTL" try-restart fprintd.service 2>/dev/null || true
    info "Your previous setup is restored"
}

# From the swap until fprintd is confirmed on the new library, any exit
# (an error, a cancelled sudo prompt, Ctrl-C) rolls back.
armed=
swapped=
on_exit() {
    local status=$?
    [ -z "$armed" ] || rollback
    as_root rm -rf "$staging" 2>/dev/null || true
    rm -rf "$tmp"
    exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP

# 1. Stage the new tree, root-owned, next to the live one.
info "Copying the library to $DGL_PREFIX"
as_root rm -rf "$staging" "$previous"
as_root install -d -m 0755 -o "$SECURE_UID" -g "$SECURE_GID" "$staging" "$staging/lib"
as_root install -m 0644 -o "$SECURE_UID" -g "$SECURE_GID" "$built_lib" "$staging/lib/$lib_name"
as_root ln -s "$lib_name" "$staging/lib/libfprint-2.so.2"
as_root install -m 0644 -o "$SECURE_UID" -g "$SECURE_GID" "$DGL_PIN_FILE" "$staging/PIN"

# Hash the root-owned copy (what fprintd will load), and make sure it is
# identical to the library the probe tested.
installed_sum=$(as_root sha256sum "$staging/lib/$lib_name" | cut -d' ' -f1)
[ "$installed_sum" = "$lib_sum" ] || die "the copied library differs from the build output; aborting"
{
    echo "fork_sha=$FORK_SHA"
    echo "fprintd_version=$(fprintd_version)"
    echo "installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "$installed_sum  lib/$lib_name"
} >"$tmp/MANIFEST"
as_root install -m 0644 -o "$SECURE_UID" -g "$SECURE_GID" "$tmp/MANIFEST" "$staging/MANIFEST"
check_secure_path "$staging/lib"

# 2. Swap it in, keeping the previous install for rollback.
armed=1
if [ -e "$prefix" ]; then
    as_root mv "$prefix" "$previous"
fi
as_root mv "$staging" "$prefix"
swapped=1

# 3. Write the drop-in.
dropin_content >"$tmp/dropin"
as_root install -d -m 0755 -o "$SECURE_UID" -g "$SECURE_GID" "$dropin_dir"
check_secure_path "$dropin_dir"
as_root install -m 0644 -o "$SECURE_UID" -g "$SECURE_GID" "$tmp/dropin" "$dropin"

# 4. Restart fprintd and check it really loaded our library. fprintd exits
# when idle, so check right away.
info "Restarting fprintd"
as_root "$SYSTEMCTL" daemon-reload
if ! as_root "$SYSTEMCTL" restart fprintd.service || ! fprintd_uses_ours; then
    die "fprintd did not start with the new library"
fi

armed=
as_root rm -rf "$previous"
info "Installed. fprintd now uses $DGL_PREFIX/lib/$lib_name"
info "Next: fprintd-enroll, then fprintd-verify (see README)."
