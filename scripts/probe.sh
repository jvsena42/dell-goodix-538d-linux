#!/usr/bin/env bash
# Check whether this laptop's sensor works with the driver, without
# installing anything. It runs one of the fork's example programs from your
# build directory, which opens the sensor and reports its firmware and key.
# Nothing is written to the sensor.
#
# Usage: scripts/probe.sh
#
# fprintd is stopped and blocked for the duration (otherwise anything asking
# for a fingerprint would restart it and grab the sensor), then unblocked.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

load_pin "$DGL_PIN_FILE"
build=$DGL_WORK_DIR/build
example=$build/examples/manage-prints
log=$DGL_WORK_DIR/probe.log
result=$DGL_WORK_DIR/probe.result

[ -x "$example" ] || die "$example not found; run scripts/build.sh first"
[ -f "$build/libfprint/libfprint-2.so.2" ] || die "no libfprint in $build; run scripts/build.sh first"
# Root is about to run code from here: make sure no other user could have
# changed it.
check_private_file "$example"
check_private_file "$build/libfprint/libfprint-2.so.2"
lib_sum=$(built_lib_sum "$build")
[ "$(build_stamp "$build")" = "$FORK_SHA $lib_sum" ] ||
    die "$build was not built from the pinned commit (or changed since); run scripts/build.sh"
sensor_present || die "no Goodix $DGL_SENSOR_VID:$DGL_SENSOR_PID sensor found (check lsusb)"

# Start clean: if an old log stayed and could not be overwritten, the probe
# would not run and the old verdict would be stamped onto this build.
rm -f "$result" "$log"

restore_fprintd() {
    as_root "$SYSTEMCTL" unmask --runtime fprintd.service >/dev/null 2>&1 || true
}
trap restore_fprintd EXIT

info "Stopping fprintd while the probe runs"
as_root "$SYSTEMCTL" mask --runtime fprintd.service >/dev/null
as_root "$SYSTEMCTL" stop fprintd.service

info "Opening the sensor (takes a few seconds)"
as_root env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    LD_LIBRARY_PATH="$build/libfprint" G_MESSAGES_DEBUG=all \
    timeout -k 5 60 "$example" </dev/null >"$log" 2>&1 || true

verdict=$(classify_probe_log "$log")
printf '%s %s %s\n' "$verdict" "$FORK_SHA" "$lib_sum" >"$result"

case $verdict in
    pass)
        info "PASS: the sensor opened (firmware GF5298_GM168SEC_APP_13016, zero key, TLS OK)."
        info "You can run scripts/install.sh."
        ;;
    incompatible)
        grep 'Invalid device ' "$log" | sed 's/^/    /' >&2
        die "the driver rejected this sensor. It needs firmware GF5298_GM168SEC_APP_13016 and an all-zero key; Windows has probably set its own. Reflashing tools exist but can brick the sensor, and this project does not support them. Do not install."
        ;;
    *)
        die "probe result: $verdict. See $log. Do not install."
        ;;
esac
