# shellcheck shell=bash
# shellcheck disable=SC2034 # constants here are used by the scripts that source this file
# Shared helpers for the scripts in scripts/. Sourced, never executed.

set -euo pipefail

DGL_REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DGL_WORK_DIR=${DGL_WORK_DIR:-$DGL_REPO_DIR/work}
DGL_PIN_FILE=$DGL_REPO_DIR/PIN

# Fixed install locations. They are not configurable on purpose: the drop-in,
# the uninstaller and the docs all refer to these exact paths.
DGL_PREFIX=/opt/dell-goodix-538d
DGL_DROPIN=/etc/systemd/system/fprintd.service.d/10-dell-goodix-538d.conf
DGL_CALIB=/var/lib/fprint/goodixtls53xd-fpn.bin
DGL_SENSOR_VID=27c6
DGL_SENSOR_PID=538d

# Commands and paths the tests replace with fakes. Overrides are honored only
# when DGL_TEST=1, so a stray SUDO=... or GIT=... in a user's environment can
# never change what runs as root.
if [ "${DGL_TEST:-}" = 1 ]; then
    ROOT=${ROOT:-/}
    SUDO=${SUDO-}
    SYSTEMCTL=${SYSTEMCTL:-systemctl}
    GIT=${GIT:-git}
    GETENT=${GETENT:-getent}
    MESON=${MESON:-meson}
    NINJA=${NINJA:-ninja}
    OBJDUMP=${OBJDUMP:-objdump}
    SECURE_UID=${SECURE_UID:-0}
    SECURE_GID=${SECURE_GID:-0}
    DGL_PIN_FILE=${TEST_PIN_FILE:-$DGL_PIN_FILE}
else
    ROOT=/
    if [ "$(id -u)" = 0 ]; then SUDO=; else SUDO=sudo; fi
    SYSTEMCTL=systemctl
    GIT=git
    GETENT=getent
    MESON=meson
    NINJA=ninja
    OBJDUMP=objdump
    SECURE_UID=0
    SECURE_GID=0
fi

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

current_uid() {
    if [ "${DGL_TEST:-}" = 1 ] && [ -n "${TEST_UID:-}" ]; then
        echo "$TEST_UID"
    else
        id -u
    fi
}

info() {
    printf '==> %s\n' "$*" >&2
}

# Map an absolute system path into $ROOT (the tests use a temporary root).
rootpath() {
    case $1 in
        /*) ;;
        *) die "rootpath needs an absolute path: $1" ;;
    esac
    printf '%s%s' "${ROOT%/}" "$1"
}

as_root() {
    if [ -n "$SUDO" ]; then
        "$SUDO" "$@"
    else
        "$@"
    fi
}

# Read KEY=value from the PIN file without sourcing it.
pin_get() {
    local key=$1 file=${2:-$DGL_PIN_FILE} value
    value=$(sed -n "s/^${key}=//p" "$file" | sed 's/[[:space:]]*$//')
    [ -n "$value" ] || die "$key missing from $file"
    [ "$(printf '%s\n' "$value" | wc -l)" = 1 ] || die "$key defined more than once in $file"
    printf '%s' "$value"
}

load_pin() {
    FORK_URL=$(pin_get FORK_URL "$@")
    FORK_SHA=$(pin_get FORK_SHA "$@")
    [[ $FORK_SHA =~ ^[0-9a-f]{40}$ ]] || die "FORK_SHA is not a full 40-character commit hash: $FORK_SHA"
    [[ $FORK_URL =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git$ ]] ||
        die "FORK_URL must be an https GitHub clone URL: $FORK_URL"
}

# Fail unless $1 is a clean checkout of exactly $2.
verify_checkout() {
    local src=$1 sha=$2 head
    [ -d "$src/.git" ] || die "$src is not a git checkout; run scripts/fetch.sh"
    [ "$(git_safe -C "$src" cat-file -t "$sha" 2>/dev/null)" = commit ] ||
        die "pinned commit $sha is not in $src"
    head=$(git_safe -C "$src" rev-parse HEAD)
    [ "$head" = "$sha" ] || die "pin mismatch: $src is at $head, expected $sha"
    [ -z "$(git_safe -C "$src" status --porcelain --untracked-files=all)" ] ||
        die "$src has local changes; delete it and run scripts/fetch.sh again"
}

# True if $1 has an extended POSIX ACL (ls marks it with "+"). The mode bits
# then do not say who can write (the group bits show the ACL mask), so such
# paths are refused outright.
has_extended_acl() {
    # ls is the only always-installed tool that shows the ACL marker.
    # shellcheck disable=SC2012
    [ "$(ls -ld -- "$1" | cut -c11)" = + ]
}

# What to do when the build tree may have been writable by others. Fixing the
# permissions is not enough: the files (and the BUILT_FROM stamp next to them)
# may already have been replaced, so the tree has to be rebuilt.
untrusted_tree_hint() {
    echo "other users may have changed files under it. Fix the permissions (chmod go-w; setfacl -b for ACLs), then delete $DGL_WORK_DIR and run scripts/fetch.sh and scripts/build.sh again"
}

# Fail unless $1 and every directory above it (up to $ROOT) is owned by
# $SECURE_UID and not writable by group or others. Used on everything root
# installs into, so no other user can swap files under it.
check_secure_path() {
    local path=$1 stop owner mode
    stop=$(cd "$ROOT" && pwd -P)
    path=$(cd "$path" && pwd -P)
    while :; do
        owner=$(stat -c %u "$path")
        mode=$(stat -c %a "$path")
        [ "$owner" = "$SECURE_UID" ] || die "$path is owned by uid $owner, expected $SECURE_UID"
        (( (8#$mode & 8#022) == 0 )) || die "$path is writable by group or others (mode $mode)"
        ! has_extended_acl "$path" || die "$path has an ACL that may let other users write to it (remove it with: setfacl -b '$path')"
        [ "$path" = "$stop" ] && break
        [ "$path" = / ] && die "$1 is outside $ROOT"
        path=$(dirname "$path")
    done
}

# True if mode $1 on something owned by uid $2 with gid $3 lets nobody but
# the owner (or root) write to it. Group write is fine when the group is the
# owner's private group with no other members (Ubuntu's default for homes):
# same name as the owner, no listed members, and no other user who has it as
# their primary group (group entries never list those). Users that NSS does
# not enumerate (some LDAP setups) cannot be seen; see README.
# A root-owned sticky directory such as /tmp is fine too: other users cannot
# rename or delete what we own inside it.
only_owner_can_write() {
    local mode=$1 owner=$2 gid=$3 entry
    (( (8#$mode & 8#1000) != 0 )) && [ "$owner" = 0 ] && return 0
    (( (8#$mode & 8#002) == 0 )) || return 1
    (( (8#$mode & 8#020) == 0 )) && return 0
    entry=$("$GETENT" group "$gid") || return 1
    # name:x:gid:members
    [ "${entry%%:*}" = "$("$GETENT" passwd "$owner" | cut -d: -f1)" ] || return 1
    [ -z "${entry##*:}" ] || return 1
    [ -z "$("$GETENT" passwd | awk -F: -v g="$gid" -v o="$owner" '$4 == g && $3 != o')" ]
}

# Fail if $1 or any directory above it is writable by group or others, or is
# owned by someone other than root or the current user. Used on the build
# directory before root runs code from it.
check_private_path() {
    local path owner mode me
    me=$(current_uid)
    path=$(cd "$1" && pwd -P)
    while :; do
        owner=$(stat -c %u "$path")
        mode=$(stat -c %a "$path")
        [ "$owner" = 0 ] || [ "$owner" = "$me" ] || die "$path is owned by uid $owner; $(untrusted_tree_hint)"
        ! has_extended_acl "$path" || die "$path has an ACL; $(untrusted_tree_hint)"
        only_owner_can_write "$mode" "$owner" "$(stat -c %g "$path")" ||
            die "$path is writable by group or others (mode $mode); $(untrusted_tree_hint)"
        [ "$path" = / ] && break
        path=$(dirname "$path")
    done
}

# check_private_path for a file: the file itself and every directory above it.
check_private_file() {
    local file=$1 owner mode
    file=$(readlink -f "$file")
    owner=$(stat -c %u "$file")
    mode=$(stat -c %a "$file")
    [ "$owner" = 0 ] || [ "$owner" = "$(current_uid)" ] || die "$file is owned by uid $owner; $(untrusted_tree_hint)"
    ! has_extended_acl "$file" || die "$file has an ACL; $(untrusted_tree_hint)"
    only_owner_can_write "$mode" "$owner" "$(stat -c %g "$file")" ||
        die "$file is writable by group or others (mode $mode); $(untrusted_tree_hint)"
    check_private_path "$(dirname "$file")"
}

# check_private_path for a whole tree: $1, every directory above it, and
# everything inside it must be owned by us (or root), not group- or
# world-writable, and without ACLs. Run it before git, meson or ninja touch a
# tree: they execute commands from files in it (.git/config, hooks,
# build.ninja). The trees are created with umask 022, so the inside gets no
# private-group exception.
check_private_tree() {
    local dir=$1 me bad
    me=$(current_uid)
    check_private_path "$dir"
    bad=$(find "$dir" ! -type l \( \( ! -uid "$me" ! -uid 0 \) -o -perm /022 \) -print -quit)
    [ -z "$bad" ] || die "$bad is writable by group or others or owned by another user; $(untrusted_tree_hint)"
    # shellcheck disable=SC2012 # ls is the only always-installed tool that shows the ACL marker
    bad=$(ls -lAR -- "$dir" | awk 'substr($1, 11, 1) == "+" { print $NF; exit }')
    [ -z "$bad" ] || die "$bad under $dir has an ACL; $(untrusted_tree_hint)"
}

# git with repository-configured programs turned off (hooks, fsmonitor), as
# defense in depth on top of check_private_tree.
git_safe() {
    "$GIT" -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

sensor_present() {
    local dev
    for dev in "$(rootpath /sys/bus/usb/devices)"/*; do
        [ -r "$dev/idVendor" ] && [ -r "$dev/idProduct" ] || continue
        if [ "$(cat "$dev/idVendor")" = "$DGL_SENSOR_VID" ] &&
            [ "$(cat "$dev/idProduct")" = "$DGL_SENSOR_PID" ]; then
            return 0
        fi
    done
    return 1
}

DGL_DROPIN_HEADER='# Installed by dell-goodix-538d-linux. Remove with scripts/uninstall.sh.'

# The drop-in that makes fprintd load our libfprint. Keep it byte-for-byte
# stable: install.sh compares against it and the tests pin it.
dropin_content() {
    cat <<EOF
$DGL_DROPIN_HEADER
[Service]
Environment=LD_LIBRARY_PATH=$DGL_PREFIX/lib
EOF
}

# libfprint symbols the given binary imports, one per line.
imported_fp_symbols() {
    "$OBJDUMP" -T "$1" | awk '/ DF \*UND\*/ && $NF ~ /^fp_/ { print $NF }' | sort -u
}

exported_fp_symbols() {
    "$OBJDUMP" -T "$1" | awk '/ DF \.text/ && $NF ~ /^fp_/ { print $NF }' | sort -u
}

# Fail if library $1 lacks any libfprint symbol that binary $2 imports.
check_symbols() {
    local lib=$1 bin=$2 imports exports missing
    imports=$(imported_fp_symbols "$bin") || die "cannot read $bin"
    [ -n "$imports" ] || die "$bin imports no libfprint functions; is fprintd installed?"
    exports=$(exported_fp_symbols "$lib") || die "cannot read $lib"
    missing=$(comm -23 <(echo "$imports") <(echo "$exports"))
    [ -z "$missing" ] || die "$lib is missing symbols $bin needs: $(tr '\n' ' ' <<<"$missing")"
}

# Classify a manage-prints log from scripts/probe.sh. Prints one of:
#   pass             sensor opened: firmware, key and TLS handshake all OK
#   incompatible     the driver rejected the sensor's firmware or key
#   open-failed      the sensor did not open for another reason
#   no-device        libfprint found no sensor
#   unknown          none of the above (e.g. the probe timed out)
# The exit code of manage-prints is not used: it always fails with
# "doesn't support storage", because the 538d driver has no on-chip storage.
classify_probe_log() {
    local log=$1
    if grep -q 'Invalid device ' "$log"; then
        echo incompatible
    elif grep -q 'Failed to open device' "$log"; then
        echo open-failed
    elif grep -q 'No devices detected' "$log"; then
        echo no-device
    elif grep -qF 'Device firmware: "GF5298_GM168SEC_APP_13016"' "$log" &&
        grep -qF 'Device PSK flags: 0xbb020001' "$log" &&
        grep -qF "doesn't support storage" "$log"; then
        echo pass
    else
        echo unknown
    fi
}

# True if the drop-in at $1 was written by this project.
dropin_is_ours() {
    [ "$(head -n 1 "$1")" = "$DGL_DROPIN_HEADER" ]
}

# PID of the running fprintd, or nothing if it is not running.
fprintd_pid() {
    local pid
    pid=$(as_root "$SYSTEMCTL" show -p MainPID --value fprintd.service)
    [ -n "$pid" ] && [ "$pid" != 0 ] && printf '%s' "$pid"
}

# True if the running fprintd has our libfprint mapped.
fprintd_uses_ours() {
    local pid
    pid=$(fprintd_pid) || return 1
    as_root grep -qF "$DGL_PREFIX/lib/libfprint-2.so" "$(rootpath "/proc/$pid/maps")"
}

fprintd_version() {
    dpkg-query -W -f='${Version}' fprintd 2>/dev/null || echo unknown
}

# "<fork sha> <sha256 of the library>" recorded by scripts/build.sh, or
# nothing if the build directory has no stamp.
build_stamp() {
    cat "$1/BUILT_FROM" 2>/dev/null || true
}

# sha256 of the library a build directory produced.
built_lib_sum() {
    sha256sum "$(readlink -f "$1/libfprint/libfprint-2.so.2")" | cut -d' ' -f1
}
