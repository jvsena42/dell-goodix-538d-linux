# shellcheck shell=bash
# scripts/install.sh

LIB=libfprint-2.so.2.0.0

ready() {
    fake_build
    probe_passed
}

test_install_copies_the_library_and_writes_the_dropin() {
    ready
    run_script install.sh
    local prefix=$ROOT/opt/dell-goodix-538d
    assert_file "$prefix/lib/$LIB"
    assert_eq "$(readlink "$prefix/lib/libfprint-2.so.2")" "$LIB"
    assert_eq "$(stat -c %a "$prefix/lib/$LIB")" 644
    assert_eq "$(stat -c %a "$prefix/lib")" 755
    assert_file "$prefix/PIN"
    assert_eq "$(cat "$ROOT/etc/systemd/system/fprintd.service.d/10-dell-goodix-538d.conf")" \
        "$(bash -c 'source lib/common.sh; dropin_content')"
    assert_no_file "$prefix.new"
    assert_no_file "$prefix.old"
}

test_install_manifest_hashes_the_installed_copy() {
    ready
    run_script install.sh
    local prefix=$ROOT/opt/dell-goodix-538d
    assert_contains "$prefix/MANIFEST" "fork_sha=$TEST_SHA"
    assert_contains "$prefix/MANIFEST" "$(sha256sum "$prefix/lib/$LIB" | cut -d' ' -f1)  lib/$LIB"
}

test_install_restarts_fprintd_and_checks_it_loaded_our_library() {
    ready
    run_script install.sh
    assert_contains "$FAKE/systemctl.log" "daemon-reload"
    assert_contains "$FAKE/systemctl.log" "restart fprintd.service"
    assert_contains "$ROOT/proc/4242/maps" "/opt/dell-goodix-538d/lib"
}

test_install_requires_a_passing_probe() {
    fake_build
    assert_fails_with "probe.sh has not passed" run_script install.sh
    echo "incompatible $TEST_SHA $(lib_sum)" >"$DGL_WORK_DIR/probe.result"
    assert_fails_with "probe.sh has not passed" run_script install.sh
    assert_no_file "$ROOT/opt/dell-goodix-538d"
}

test_install_rejects_a_probe_from_another_pin() {
    fake_build
    echo "pass 037912c17992d2abc81c79c40e85b45ba1d3871e $(lib_sum)" >"$DGL_WORK_DIR/probe.result"
    assert_fails_with "probe.sh has not passed" run_script install.sh
}

test_install_force_skips_the_probe() {
    fake_build
    run_script install.sh --force
    assert_file "$ROOT/opt/dell-goodix-538d/MANIFEST"
}

test_install_refuses_a_library_missing_symbols_before_touching_anything() {
    fake_build fp_context_new fp_device_open
    probe_passed
    assert_fails_with "fp_device_verify" run_script install.sh
    assert_no_file "$ROOT/opt/dell-goodix-538d"
    assert_no_file "$FAKE/systemctl.log"
}

test_install_rolls_back_when_fprintd_fails_to_start() {
    ready
    touch "$FAKE/fprintd-fails"
    assert_fails_with "previous setup is restored" run_script install.sh
    assert_no_file "$ROOT/opt/dell-goodix-538d"
    assert_no_file "$ROOT/etc/systemd/system/fprintd.service.d/10-dell-goodix-538d.conf"
    assert_contains "$FAKE/systemctl.log" "reset-failed fprintd.service"
}

test_install_rolls_back_when_fprintd_ignores_our_library() {
    ready
    touch "$FAKE/ignore-dropin"
    assert_fails_with "previous setup is restored" run_script install.sh
    assert_no_file "$ROOT/opt/dell-goodix-538d"
}

test_rollback_restores_the_previous_install() {
    ready
    run_script install.sh
    local old_manifest
    old_manifest=$(cat "$ROOT/opt/dell-goodix-538d/MANIFEST")
    sleep 1
    touch "$FAKE/fprintd-fails"
    assert_fails_with "previous setup is restored" run_script install.sh
    assert_eq "$(cat "$ROOT/opt/dell-goodix-538d/MANIFEST")" "$old_manifest"
    assert_file "$ROOT/etc/systemd/system/fprintd.service.d/10-dell-goodix-538d.conf"
    assert_no_file "$ROOT/opt/dell-goodix-538d.old"
}

test_install_twice_is_fine() {
    ready
    run_script install.sh
    run_script install.sh
    assert_file "$ROOT/opt/dell-goodix-538d/lib/$LIB"
    assert_no_file "$ROOT/opt/dell-goodix-538d.old"
}

test_install_refuses_a_foreign_dropin() {
    ready
    mkdir -p "$ROOT/etc/systemd/system/fprintd.service.d"
    printf '[Service]\nEnvironment=FOO=1\n' >"$ROOT/etc/systemd/system/fprintd.service.d/10-dell-goodix-538d.conf"
    assert_fails_with "not written by this project" run_script install.sh
    assert_no_file "$ROOT/opt/dell-goodix-538d"
}

test_install_refuses_a_foreign_prefix() {
    ready
    mkdir -p "$ROOT/opt/dell-goodix-538d"
    assert_fails_with "not installed by this project" run_script install.sh
}

test_install_refuses_an_insecure_opt() {
    ready
    chmod o+w "$ROOT/opt"
    assert_fails_with "writable by group or others" run_script install.sh
    assert_no_file "$ROOT/opt/dell-goodix-538d"
}

test_install_refuses_a_build_dir_others_can_write() {
    ready
    chmod g+w "$DGL_WORK_DIR/build/libfprint"
    assert_fails_with "writable by group or others" run_script install.sh
}

test_install_rejects_unknown_options() {
    assert_fails_with "usage" run_script install.sh --yes
}

test_install_refuses_a_library_file_others_can_write() {
    ready
    chmod o+w "$DGL_WORK_DIR/build/libfprint/$LIB"
    assert_fails_with "writable by group or others" run_script install.sh
}

test_install_refuses_a_probe_of_an_earlier_build() {
    ready
    echo "rebuilt" >>"$DGL_WORK_DIR/build/libfprint/$LIB"
    echo "$TEST_SHA $(lib_sum)" >"$DGL_WORK_DIR/build/BUILT_FROM"
    assert_fails_with "probe.sh has not passed for this build" run_script install.sh
}

test_install_refuses_a_build_without_a_stamp() {
    ready
    rm "$DGL_WORK_DIR/build/BUILT_FROM"
    assert_fails_with "not built from the pinned commit" run_script install.sh --force
}

test_install_refuses_a_build_of_another_commit() {
    ready
    echo "037912c17992d2abc81c79c40e85b45ba1d3871e $(lib_sum)" >"$DGL_WORK_DIR/build/BUILT_FROM"
    assert_fails_with "not built from the pinned commit" run_script install.sh --force
}

test_install_rolls_back_on_any_error_after_the_swap() {
    ready
    run_script install.sh
    local old_manifest
    old_manifest=$(cat "$ROOT/opt/dell-goodix-538d/MANIFEST")
    sleep 1
    touch "$FAKE/daemon-reload-fails"
    assert_fails_with "previous setup is restored" run_script install.sh
    assert_eq "$(cat "$ROOT/opt/dell-goodix-538d/MANIFEST")" "$old_manifest"
    assert_no_file "$ROOT/opt/dell-goodix-538d.old"
    assert_no_file "$ROOT/opt/dell-goodix-538d.new"
}

test_install_accepts_a_private_group_writable_home() {
    ready
    chmod g+w "$DGL_WORK_DIR"
    echo "me:x:$(id -g):" >"$FAKE/group"
    run_script install.sh
}
