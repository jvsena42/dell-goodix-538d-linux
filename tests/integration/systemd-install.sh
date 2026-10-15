#!/usr/bin/env bash
# Integration test: the real install.sh, verify.sh and uninstall.sh against a
# real systemd and a D-Bus-activated fprintd, including the failure paths.
#
# This does a real install, so it refuses to run outside a container. CI
# boots ci/Dockerfile with systemd as PID 1 and runs it there:
#
#   DGL_INTEGRATION=1 tests/integration/systemd-install.sh
#
# Needs a finished scripts/build.sh in work/build.

set -euo pipefail
cd "$(dirname "$0")/../.."
repo=$PWD

[ "${DGL_INTEGRATION:-}" = 1 ] || { echo "set DGL_INTEGRATION=1 to run" >&2; exit 2; }
[ -f /.dockerenv ] || [ -n "${container:-}" ] || { echo "refusing to run outside a container: this does a real install" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root (inside the container)" >&2; exit 2; }
[ -d /run/systemd/system ] || { echo "systemd is not running as init" >&2; exit 2; }
[ -f work/build/libfprint/libfprint-2.so.2 ] || { echo "run scripts/build.sh first" >&2; exit 2; }

prefix=/opt/dell-goodix-538d
dropin=/etc/systemd/system/fprintd.service.d/10-dell-goodix-538d.conf

# Root-owned work dirs, as a root-run install requires.
export DGL_WORK_DIR=/var/tmp/dgl-work
rm -rf "$DGL_WORK_DIR" && mkdir -p "$DGL_WORK_DIR"

# shellcheck source=lib/common.sh
source lib/common.sh
load_pin "$DGL_PIN_FILE"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok    $*"; }

# Start fprintd through D-Bus activation (the way PAM and GNOME reach it)
# and print which libfprint it mapped.
fprintd_lib() {
    timeout 10 gdbus call --system --dest net.reactivated.Fprint \
        --object-path /net/reactivated/Fprint/Manager \
        --method net.reactivated.Fprint.Manager.GetDevices >/dev/null 2>&1 || true
    local pid
    pid=$(systemctl show -p MainPID --value fprintd.service)
    [ "$pid" != 0 ] || { echo none; return; }
    grep -o '/[^ ]*libfprint-2\.so[^ ]*' "/proc/$pid/maps" | head -n 1
}

# Point $DGL_WORK_DIR/build at a library.
use_build() {
    rm -rf "$DGL_WORK_DIR/build"
    mkdir -p "$DGL_WORK_DIR/build/libfprint"
    cp "$1" "$DGL_WORK_DIR/build/libfprint/libfprint-2.so.2.0.0"
    ln -s libfprint-2.so.2.0.0 "$DGL_WORK_DIR/build/libfprint/libfprint-2.so.2"
    # Stamp it as build.sh would.
    echo "$FORK_SHA $(built_lib_sum "$DGL_WORK_DIR/build")" >"$DGL_WORK_DIR/build/BUILT_FROM"
}

# A library exporting every symbol fprintd needs, as stubs; $1 is extra C.
stub_lib() {
    local dir=$DGL_WORK_DIR/stub
    mkdir -p "$dir"
    {
        echo "$1"
        imported_fp_symbols /usr/libexec/fprintd | sed 's/.*/void &(void) {}/'
    } >"$dir/stub.c"
    echo 'LIBFPRINT_2.0.0 { global: fp_*; local: *; };' >"$dir/stub.ver"
    gcc -shared -fPIC -o "$dir/libfprint-2.so.2.0.0" "$dir/stub.c" \
        -Wl,-soname,libfprint-2.so.2 -Wl,--version-script,"$dir/stub.ver"
    echo "$dir/libfprint-2.so.2.0.0"
}

assert_clean() {
    [ ! -e "$prefix" ] || fail "$prefix should not exist"
    [ ! -e "$dropin" ] || fail "$dropin should not exist"
    case $(fprintd_lib) in
        /usr/lib/*) ;;
        *) fail "fprintd should be back on Ubuntu's libfprint, got $(fprintd_lib)" ;;
    esac
}

systemctl is-system-running --wait >/dev/null 2>&1 || true
assert_clean
ok "baseline: fprintd runs on Ubuntu's libfprint"

# 1. A library missing symbols is refused before anything changes.
echo 'int nothing;' | gcc -shared -fPIC -x c -o "$DGL_WORK_DIR/empty.so" -
use_build "$DGL_WORK_DIR/empty.so"
if scripts/install.sh --force >/dev/null 2>&1; then fail "install accepted a library without symbols"; fi
assert_clean
ok "install refuses a library missing fprintd's symbols"

# 2. A library that kills fprintd on start triggers a rollback.
use_build "$(stub_lib '#include <stdlib.h>
__attribute__((constructor)) static void crash(void) { abort(); }')"
if scripts/install.sh --force >/dev/null 2>&1; then fail "install succeeded although fprintd crashes"; fi
assert_clean
ok "a crashing fprintd is rolled back to Ubuntu's libfprint"

# 3. The real build installs, verifies, and is used by D-Bus activation.
use_build "$(readlink -f "$repo/work/build/libfprint/libfprint-2.so.2")"
scripts/install.sh --force
scripts/verify.sh
systemctl stop fprintd.service
case $(fprintd_lib) in
    "$prefix"/lib/*) ;;
    *) fail "D-Bus-activated fprintd is not using $prefix/lib: $(fprintd_lib)" ;;
esac
timeout 30 fprintd-list root >/dev/null 2>&1 || fail "fprintd does not answer"
ok "install + verify; D-Bus-activated fprintd uses $prefix/lib"

# 4. Installing again is fine; a failed upgrade restores the working install.
scripts/install.sh --force >/dev/null
before=$(cat "$prefix/MANIFEST")
use_build "$(stub_lib '#include <stdlib.h>
__attribute__((constructor)) static void crash(void) { abort(); }')"
if scripts/install.sh --force >/dev/null 2>&1; then fail "a crashing upgrade was accepted"; fi
[ "$(cat "$prefix/MANIFEST")" = "$before" ] || fail "the previous install was not restored"
scripts/verify.sh >/dev/null
ok "re-install works; a failed upgrade restores the previous install"

# 5. verify.sh notices tampering.
cp "$dropin" "$DGL_WORK_DIR/dropin.bak"
echo "Environment=LD_PRELOAD=/tmp/evil.so" >>"$dropin"
if scripts/verify.sh >/dev/null 2>&1; then fail "verify missed a modified drop-in"; fi
cp "$DGL_WORK_DIR/dropin.bak" "$dropin"
ok "verify detects a modified drop-in"

# 6. Uninstall restores Ubuntu's setup, and twice is harmless.
mkdir -p /var/lib/fprint && echo x >/var/lib/fprint/goodixtls53xd-fpn.bin
scripts/uninstall.sh
[ ! -e /var/lib/fprint/goodixtls53xd-fpn.bin ] || fail "calibration file left behind"
assert_clean
scripts/uninstall.sh 2>&1 | grep -q "Nothing to uninstall" || fail "second uninstall was not a no-op"
ok "uninstall restores Ubuntu's libfprint; running it twice is a no-op"
