# shellcheck shell=bash
# Sandbox, fakes and assertions shared by the tests. Sourced by tests/run.sh.

REPO=$(pwd)
TEST_SHA=$(printf 'a%.0s' {1..40})

setup_sandbox() {
    umask 022
    TMP=$(mktemp -d)
    export DGL_TEST=1
    export ROOT=$TMP/root
    export DGL_WORK_DIR=$TMP/work
    export SUDO=
    export SECURE_UID SECURE_GID
    SECURE_UID=$(id -u)
    SECURE_GID=$(id -g)
    export SYSTEMCTL=$TMP/bin/systemctl
    export OBJDUMP=$TMP/bin/objdump
    export MESON=$TMP/bin/meson
    export NINJA=$TMP/bin/ninja
    export GETENT=$TMP/bin/getent
    export TEST_PIN_FILE=$TMP/PIN
    # Act as a normal user even when the tests run as root (CI containers).
    export TEST_UID
    TEST_UID=$(id -u)
    [ "$TEST_UID" != 0 ] || TEST_UID=1000
    export FAKE=$TMP/fake

    mkdir -p "$ROOT"/{opt,etc/systemd/system,usr/libexec,var/lib/fprint,proc,sys/bus/usb/devices} \
        "$TMP/bin" "$FAKE" "$DGL_WORK_DIR"
    chmod 0755 "$ROOT"
    write_pin "https://github.com/test/libfprint.git" "$TEST_SHA"
    install_fakes
    # Ubuntu's fprintd imports these three libfprint functions (in this sandbox).
    fake_symbols "$ROOT/usr/libexec/fprintd" UND fp_context_new fp_device_open fp_device_verify
}

teardown_sandbox() {
    chmod -R u+w "$TMP" 2>/dev/null
    rm -rf "$TMP"
}

write_pin() {
    printf '# test pin\nFORK_URL=%s\nFORK_SHA=%s\n' "$1" "$2" >"$TEST_PIN_FILE"
}

# Write a file in `objdump -T` format; the fake objdump just prints it.
#   fake_symbols FILE UND|DEF SYMBOL...
fake_symbols() {
    local file=$1 kind=$2 sym
    shift 2
    mkdir -p "$(dirname "$file")"
    : >"$file"
    for sym in "$@"; do
        if [ "$kind" = UND ]; then
            printf '0000000000000000      DF *UND*\t0000000000000000 (LIBFPRINT_2.0.0) %s\n' "$sym" >>"$file"
        else
            printf '0000000000016510 g    DF .text\t000000000000001a  LIBFPRINT_2.0.0 %s\n' "$sym" >>"$file"
        fi
    done
}

# A finished build in $DGL_WORK_DIR/build exporting the given symbols (by
# default everything the sandbox fprintd needs).
fake_build() {
    local build=$DGL_WORK_DIR/build
    mkdir -p "$build/libfprint" "$build/examples"
    if [ "$#" = 0 ]; then
        set -- fp_context_new fp_device_open fp_device_verify
    fi
    fake_symbols "$build/libfprint/libfprint-2.so.2.0.0" DEF "$@"
    ln -sf libfprint-2.so.2.0.0 "$build/libfprint/libfprint-2.so.2"
    echo "$TEST_SHA $(lib_sum)" >"$build/BUILT_FROM"
}

lib_sum() {
    sha256sum "$DGL_WORK_DIR/build/libfprint/libfprint-2.so.2.0.0" | cut -d' ' -f1
}

fake_sensor() {
    mkdir -p "$ROOT/sys/bus/usb/devices/3-2"
    echo 27c6 >"$ROOT/sys/bus/usb/devices/3-2/idVendor"
    echo 538d >"$ROOT/sys/bus/usb/devices/3-2/idProduct"
}

probe_passed() {
    echo "pass $TEST_SHA $(lib_sum)" >"$DGL_WORK_DIR/probe.result"
}

install_fakes() {
    # objdump -T FILE: print the fake symbol table.
    cat >"$TMP/bin/objdump" <<'FAKE'
#!/usr/bin/env bash
cat "$2"
FAKE

    # getent: by default every group is shared ("staff", with a member), so
    # group-writable paths are refused. Tests write $FAKE/group to change it.
    cat >"$TMP/bin/getent" <<'FAKE'
#!/usr/bin/env bash
case $1 in
    group) if [ -f "$FAKE/group" ]; then cat "$FAKE/group"; else echo "staff:x:$2:alice"; fi ;;
    passwd) echo "me:x:$2:$2::/home/me:/bin/bash" ;;
esac
FAKE

    # meson/ninja: record the arguments, produce a fake build.
    cat >"$TMP/bin/meson" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/meson.log"
FAKE
    cat >"$TMP/bin/ninja" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/ninja.log"
mkdir -p "$2/libfprint" && touch "$2/libfprint/libfprint-2.so.2"
FAKE

    # systemctl: log every call. "daemon-reload-fails" in $FAKE makes
    # daemon-reload fail. fprintd "starts" with pid 4242 and maps our
    # library if the drop-in exists. Behavior switches (files in $FAKE):
    #   fprintd-fails        restart/start fail
    #   ignore-dropin        fprintd starts but without our library
    cat >"$TMP/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/systemctl.log"
dropin=$ROOT/etc/systemd/system/fprintd.service.d/10-dell-goodix-538d.conf
case $1 in
    daemon-reload) [ ! -e "$FAKE/daemon-reload-fails" ] || exit 1 ;;
    restart|start)
        [ -e "$FAKE/fprintd-fails" ] && { echo 0 >"$FAKE/pid"; exit 1; }
        mkdir -p "$ROOT/proc/4242"
        if [ -f "$dropin" ] && [ ! -e "$FAKE/ignore-dropin" ]; then
            echo "7f00 r-xp /opt/dell-goodix-538d/lib/libfprint-2.so.2.0.0" >"$ROOT/proc/4242/maps"
        else
            echo "7f00 r-xp /usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0" >"$ROOT/proc/4242/maps"
        fi
        echo 4242 >"$FAKE/pid"
        ;;
    show) cat "$FAKE/pid" 2>/dev/null || echo 0 ;;
    try-restart)
        [ "$(cat "$FAKE/pid" 2>/dev/null)" = 4242 ] && exec "$0" restart
        exit 0
        ;;
esac
exit 0
FAKE
    chmod +x "$TMP"/bin/*
}

# --- assertions -------------------------------------------------------------

fail() {
    printf 'assertion failed: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || fail "${3:-values differ}"$'\n'"  expected: $2"$'\n'"  actual:   $1"
}

assert_file() { [ -f "$1" ] || fail "missing file $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "should not exist: $1"; }

assert_contains() {
    grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 does not contain: $2"
}

assert_not_contains() {
    ! grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 should not contain: $2"
}

# Run a command that must fail and whose stderr must contain $1.
assert_fails_with() {
    local expected=$1 out
    shift
    if out=$("$@" 2>&1); then
        fail "expected failure from: $*"$'\n'"$out"
    fi
    [[ $out == *"$expected"* ]] || fail "error should mention '$expected', got:"$'\n'"$out"
}

run_script() {
    "$REPO/scripts/$1" "${@:2}"
}
