#!/usr/bin/env bash
# Build the pinned fork as your normal user. Nothing is installed.
#
# Usage: scripts/build.sh [--test-build]
#
# --test-build also compiles libfprint's virtual drivers, into work/build-test,
# for the integration tests. That build is never installed.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

drivers=default
build=$DGL_WORK_DIR/build
case ${1:-} in
    "") ;;
    --test-build)
        drivers=all
        build=$DGL_WORK_DIR/build-test
        ;;
    *) die "usage: $0 [--test-build]" ;;
esac

if [ "$(current_uid)" = 0 ] && [ "${ALLOW_ROOT_BUILD:-}" != 1 ]; then
    die "do not build as root; run this as your normal user (CI sets ALLOW_ROOT_BUILD=1)"
fi

load_pin "$DGL_PIN_FILE"
src=$DGL_WORK_DIR/src
verify_checkout "$src" "$FORK_SHA"

umask 022
# Python helpers run during the build must not leave __pycache__ in the
# pinned source tree, or the next verify_checkout would reject it.
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$build"
setup=(setup)
[ -f "$build/build.ninja" ] && setup+=(--reconfigure)

info "Configuring ($drivers drivers) in $build"
# --wrap-mode=nodownload: meson must never fetch anything during the build.
# Introspection stays on because the fork's tests/meson.build fails to
# configure without it.
"$MESON" "${setup[@]}" "$build" "$src" \
    --prefix="$DGL_PREFIX" --libdir=lib --buildtype=release \
    -Ddrivers="$drivers" \
    -Ddoc=false -Dintrospection=true -Dinstalled-tests=false \
    -Dgtk-examples=false -Dudev_rules=disabled -Dudev_hwdb=disabled \
    --wrap-mode=nodownload

info "Compiling"
"$NINJA" -C "$build"
[ -f "$build/libfprint/libfprint-2.so.2" ] || die "build finished without libfprint-2.so.2"
# Stamp the build so probe.sh and install.sh can tell exactly what they test
# and install.
printf '%s %s\n' "$FORK_SHA" "$(built_lib_sum "$build")" >"$build/BUILT_FROM"
info "Built $build/libfprint/libfprint-2.so.2"
