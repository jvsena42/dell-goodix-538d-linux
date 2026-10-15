#!/usr/bin/env bash
# Integration test: Ubuntu's own fprintd, running on the libfprint we build,
# drives libfprint's virtual sensor through enroll, verify and delete with
# the real fprintd-* command-line tools.
#
# It starts a private D-Bus and a temporary fprintd; nothing on the host is
# changed, but it runs fprintd as root, so it only runs when asked to:
#
#   DGL_INTEGRATION=1 tests/integration/fprintd-virtual.sh
#
# Needs: scripts/build.sh --test-build, plus fprintd, dbus, python3 and
# python3-dbusmock (all in ci/Dockerfile).

set -euo pipefail
cd "$(dirname "$0")/../.."

[ "${DGL_INTEGRATION:-}" = 1 ] || { echo "set DGL_INTEGRATION=1 to run (starts fprintd as root)" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root (inside the CI container)" >&2; exit 2; }

lib=$PWD/work/build-test/libfprint
[ -f "$lib/libfprint-2.so.2" ] || { echo "run scripts/build.sh --test-build first" >&2; exit 2; }

tmp=$(mktemp -d)
pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    [ -f "$tmp/fprintd.log" ] && sed 's/^/  fprintd: /' "$tmp/fprintd.log" | tail -40 >&2
    exit 1
}

wait_for() {
    local what=$1
    shift
    for _ in $(seq 100); do
        "$@" && return 0
        sleep 0.1
    done
    fail "timed out waiting for $what"
}

# Send one command to the virtual sensor (one connection per command).
sensor() {
    python3 -I -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(" ".join(sys.argv[2:]).encode())
s.close()' "$tmp/virtual.sock" "$@"
}

# 1. A private system bus that lets anyone own any name.
cat >"$tmp/bus.conf" <<CONF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=$tmp/bus.sock</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
CONF
dbus-daemon --config-file="$tmp/bus.conf" --nofork --nopidfile &
pids+=($!)
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$tmp/bus.sock
wait_for "the bus" test -S "$tmp/bus.sock"

# 2. A fake polkit that authorizes everything.
python3 -m dbusmock --system --template polkitd >"$tmp/polkit.log" 2>&1 &
pids+=($!)
wait_for "polkit" timeout 2 gdbus call --system --dest org.freedesktop.PolicyKit1 \
    --object-path /org/freedesktop/PolicyKit1/Authority \
    --method org.freedesktop.DBus.Mock.AllowUnknown true >/dev/null 2>&1

# 3. Ubuntu's fprintd on our library, with only the virtual sensor enabled.
mkdir -m 0700 "$tmp/state"
env LD_LIBRARY_PATH="$lib" STATE_DIRECTORY="$tmp/state" \
    FP_VIRTUAL_DEVICE="$tmp/virtual.sock" FP_DRIVERS_ALLOWLIST=virtual_device \
    G_MESSAGES_DEBUG=all /usr/libexec/fprintd --no-timeout >"$tmp/fprintd.log" 2>&1 &
fprintd=$!
pids+=("$fprintd")
wait_for "fprintd on the bus" timeout 2 gdbus introspect --system --dest net.reactivated.Fprint \
    --object-path /net/reactivated/Fprint/Manager >/dev/null 2>&1

grep -qF "$lib/libfprint-2.so" "/proc/$fprintd/maps" ||
    fail "fprintd did not load $lib (it is using another libfprint)"
echo "ok    fprintd runs on the built libfprint"

timeout 30 fprintd-list root >"$tmp/list.out" 2>&1 || true
grep -q "Virtual device" "$tmp/list.out" || { cat "$tmp/list.out"; fail "fprintd-list does not show the virtual sensor"; }
echo "ok    fprintd-list shows the sensor"

# 4. Enroll: the sensor's socket appears once fprintd opens it.
timeout 60 fprintd-enroll -f right-index-finger root >"$tmp/enroll.out" 2>&1 &
enroll=$!
wait_for "the virtual sensor" test -S "$tmp/virtual.sock"
sensor SET_ENROLL_STAGES 3
for _ in 1 2 3; do sensor SCAN finger-a; done
wait "$enroll" || { cat "$tmp/enroll.out"; fail "fprintd-enroll failed"; }
grep -q "enroll-completed" "$tmp/enroll.out" || { cat "$tmp/enroll.out"; fail "enrollment did not complete"; }
echo "ok    fprintd-enroll completes"

# 5. Verify with the right finger, then with another one.
# Scan only once fprintd-verify reports it has started: the sensor socket from
# enrollment is left behind when the device closes, so its existence proves
# nothing, and a scan sent too early fails. stdbuf keeps the output unbuffered.
verify() {
    : >"$tmp/verify.out"
    timeout 60 stdbuf -oL fprintd-verify root >"$tmp/verify.out" 2>&1 &
    local v=$!
    wait_for "fprintd-verify to start" grep -q "Verify started" "$tmp/verify.out"
    sensor SCAN "$1" || fail "could not send a scan to the virtual sensor"
    wait "$v" || true
}
verify finger-a
grep -q "verify-match" "$tmp/verify.out" || { cat "$tmp/verify.out"; fail "the enrolled finger was not accepted"; }
echo "ok    fprintd-verify accepts the enrolled finger"
verify finger-b
grep -q "verify-no-match" "$tmp/verify.out" || { cat "$tmp/verify.out"; fail "another finger was not rejected"; }
echo "ok    fprintd-verify rejects another finger"

# 6. Delete.
timeout 30 fprintd-delete root >/dev/null 2>&1 || fail "fprintd-delete failed"
timeout 30 fprintd-list root 2>&1 | grep -q "has no fingers enrolled" || fail "prints still listed after fprintd-delete"
echo "ok    fprintd-delete removes the prints"
