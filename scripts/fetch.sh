#!/usr/bin/env bash
# Clone the pinned libfprint fork into work/src and check out exactly the
# commit in PIN. Runs as your normal user; needs no root.
#
# Usage: scripts/fetch.sh

# shellcheck source=lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

load_pin "$DGL_PIN_FILE"
umask 022
# Never populate a tree other users could write to: root later runs and
# copies what is built here.
mkdir -p "$DGL_WORK_DIR"
check_private_path "$DGL_WORK_DIR"
src=$DGL_WORK_DIR/src

if [ -d "$src/.git" ]; then
    url=$("$GIT" -C "$src" config --get remote.origin.url)
    [ "$url" = "$FORK_URL" ] || die "$src points at $url, not $FORK_URL; delete it and re-run"
    if [ "$("$GIT" -C "$src" cat-file -t "$FORK_SHA" 2>/dev/null)" != commit ]; then
        info "Fetching $FORK_URL"
        "$GIT" -C "$src" fetch --quiet origin
    fi
else
    info "Cloning $FORK_URL"
    "$GIT" clone --quiet --no-checkout "$FORK_URL" "$src"
fi

"$GIT" -C "$src" -c advice.detachedHead=false checkout --quiet --detach "$FORK_SHA"
verify_checkout "$src" "$FORK_SHA"
# The security review assumes nothing else is pulled into the build.
[ ! -e "$src/.gitmodules" ] && [ ! -e "$src/subprojects" ] ||
    die "the pinned commit has submodules or meson subprojects; review them before building"
info "Source is at the pinned commit $FORK_SHA"
