# shellcheck shell=bash
# scripts/probe.sh, with a fake manage-prints that prints a fixture log.

# fake_example FIXTURE [EXIT_CODE]
fake_example() {
    fake_build
    cat >"$DGL_WORK_DIR/build/examples/manage-prints" <<FAKE
#!/bin/sh
cat "$REPO/tests/fixtures/$1"
exit ${2:-1}
FAKE
    chmod +x "$DGL_WORK_DIR/build/examples/manage-prints"
}

test_probe_passes_even_though_manage_prints_exits_nonzero() {
    fake_sensor
    fake_example probe-pass.log 1
    run_script probe.sh
    assert_eq "$(cat "$DGL_WORK_DIR/probe.result")" "pass $TEST_SHA $(lib_sum)"
}

test_probe_blocks_fprintd_and_always_unblocks_it() {
    fake_sensor
    fake_example probe-pass.log
    run_script probe.sh
    assert_eq "$(cat "$FAKE/systemctl.log")" "mask --runtime fprintd.service
stop fprintd.service
unmask --runtime fprintd.service"
}

test_probe_reports_an_incompatible_sensor_and_still_unblocks_fprintd() {
    fake_sensor
    fake_example probe-bad-psk.log
    assert_fails_with "Do not install" run_script probe.sh
    assert_eq "$(cat "$DGL_WORK_DIR/probe.result")" "incompatible $TEST_SHA $(lib_sum)"
    assert_contains "$FAKE/systemctl.log" "unmask --runtime fprintd.service"
}

test_probe_reports_wrong_firmware() {
    fake_sensor
    fake_example probe-bad-firmware.log
    assert_fails_with "Invalid device firmware" run_script probe.sh
}

test_probe_does_not_pass_on_a_timeout() {
    fake_sensor
    fake_example probe-timeout.log 124
    assert_fails_with "probe result: unknown" run_script probe.sh
}

test_probe_needs_the_sensor() {
    fake_example probe-pass.log
    assert_fails_with "no Goodix 27c6:538d sensor" run_script probe.sh
    assert_no_file "$FAKE/systemctl.log"
}

test_probe_refuses_a_build_dir_others_can_write() {
    fake_sensor
    fake_example probe-pass.log
    chmod o+w "$DGL_WORK_DIR/build"
    assert_fails_with "writable by group or others" run_script probe.sh
    assert_no_file "$FAKE/systemctl.log"
}

test_probe_needs_a_build() {
    fake_sensor
    assert_fails_with "run scripts/build.sh first" run_script probe.sh
}

test_probe_refuses_a_library_others_can_write() {
    fake_sensor
    fake_example probe-pass.log
    chmod g+w "$DGL_WORK_DIR/build/libfprint/libfprint-2.so.2.0.0"
    assert_fails_with "writable by group or others" run_script probe.sh
    assert_no_file "$FAKE/systemctl.log"
}

test_probe_refuses_a_build_that_changed_after_build_sh() {
    fake_sensor
    fake_example probe-pass.log
    echo changed >>"$DGL_WORK_DIR/build/libfprint/libfprint-2.so.2.0.0"
    assert_fails_with "not built from the pinned commit" run_script probe.sh
    assert_no_file "$FAKE/systemctl.log"
}

test_classify_probe_log() {
    # shellcheck source=lib/common.sh
    source "$REPO/lib/common.sh"
    local f=$REPO/tests/fixtures
    assert_eq "$(classify_probe_log "$f/probe-pass.log")" pass
    assert_eq "$(classify_probe_log "$f/probe-bad-psk.log")" incompatible
    assert_eq "$(classify_probe_log "$f/probe-bad-firmware.log")" incompatible
    assert_eq "$(classify_probe_log "$f/probe-open-failed.log")" open-failed
    assert_eq "$(classify_probe_log "$f/probe-no-device.log")" no-device
    assert_eq "$(classify_probe_log "$f/probe-timeout.log")" unknown
    assert_eq "$(classify_probe_log /dev/null)" unknown
}
