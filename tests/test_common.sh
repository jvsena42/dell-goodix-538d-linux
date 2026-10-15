# shellcheck shell=bash
# lib/common.sh

lib() {
    # shellcheck source=lib/common.sh
    source "$REPO/lib/common.sh"
}

test_load_pin_accepts_the_repo_pin() {
    lib
    load_pin "$REPO/PIN"
    assert_eq "$FORK_URL" https://github.com/lbssousa/libfprint.git
    assert_eq "$FORK_SHA" 037912c17992d2abc81c79c40e85b45ba1d3871e
}

test_load_pin_rejects_a_short_sha() {
    lib
    write_pin https://github.com/test/libfprint.git 037912c
    assert_fails_with "full 40-character" load_pin
}

test_load_pin_rejects_a_non_github_url() {
    lib
    write_pin http://example.com/libfprint.git "$TEST_SHA"
    assert_fails_with "https GitHub clone URL" load_pin
}

test_load_pin_rejects_a_duplicated_key() {
    lib
    write_pin https://github.com/test/libfprint.git "$TEST_SHA"
    echo "FORK_SHA=$TEST_SHA" >>"$TEST_PIN_FILE"
    assert_fails_with "more than once" load_pin
}

test_load_pin_rejects_a_missing_key() {
    lib
    echo "FORK_URL=https://github.com/test/libfprint.git" >"$TEST_PIN_FILE"
    assert_fails_with "FORK_SHA missing" load_pin
}

test_overrides_are_ignored_outside_test_mode() {
    local out
    # shellcheck disable=SC2016 # expanded by the inner bash
    out=$(env -u DGL_TEST SUDO=/tmp/evil ROOT=/tmp/x SYSTEMCTL=/tmp/evil SECURE_UID=1234 \
        bash -c 'source lib/common.sh; echo "$ROOT|$SYSTEMCTL|$SECURE_UID|${SUDO:-none}"')
    if [ "$(id -u)" = 0 ]; then
        assert_eq "$out" "/|systemctl|0|none"
    else
        assert_eq "$out" "/|systemctl|0|sudo"
    fi
}

test_rootpath_maps_into_the_sandbox() {
    lib
    assert_eq "$(rootpath /opt/x)" "$ROOT/opt/x"
    assert_fails_with "absolute path" rootpath opt/x
}

test_check_secure_path_accepts_a_clean_tree() {
    lib
    check_secure_path "$ROOT/opt"
}

test_check_secure_path_rejects_a_group_writable_parent() {
    lib
    mkdir -p "$ROOT/opt/a/b"
    chmod g+w "$ROOT/opt/a"
    assert_fails_with "writable by group or others" check_secure_path "$ROOT/opt/a/b"
}

test_check_secure_path_rejects_the_wrong_owner() {
    lib
    SECURE_UID=99999
    assert_fails_with "expected 99999" check_secure_path "$ROOT/opt"
}

test_check_private_path_rejects_a_world_writable_dir() {
    lib
    mkdir -p "$DGL_WORK_DIR/build"
    chmod o+w "$DGL_WORK_DIR/build"
    assert_fails_with "writable by group or others" check_private_path "$DGL_WORK_DIR/build"
}

test_dropin_content_is_exact() {
    lib
    assert_eq "$(dropin_content)" "# Installed by dell-goodix-538d-linux. Remove with scripts/uninstall.sh.
[Service]
Environment=LD_LIBRARY_PATH=/opt/dell-goodix-538d/lib"
}

test_check_symbols_passes_when_everything_is_exported() {
    lib
    fake_build
    check_symbols "$DGL_WORK_DIR/build/libfprint/libfprint-2.so.2.0.0" "$ROOT/usr/libexec/fprintd"
}

test_check_symbols_names_the_missing_symbol() {
    lib
    fake_build fp_context_new fp_device_open
    assert_fails_with "fp_device_verify" \
        check_symbols "$DGL_WORK_DIR/build/libfprint/libfprint-2.so.2.0.0" "$ROOT/usr/libexec/fprintd"
}

test_sensor_present_finds_the_538d() {
    lib
    ! sensor_present || fail "no sensor yet"
    fake_sensor
    sensor_present
}

test_sensor_present_ignores_other_goodix_sensors() {
    lib
    mkdir -p "$ROOT/sys/bus/usb/devices/3-2"
    echo 27c6 >"$ROOT/sys/bus/usb/devices/3-2/idVendor"
    echo 538c >"$ROOT/sys/bus/usb/devices/3-2/idProduct"
    ! sensor_present || fail "538c is not our sensor"
}

test_load_pin_tolerates_crlf_and_trailing_spaces() {
    lib
    printf 'FORK_URL=https://github.com/test/libfprint.git  \r\nFORK_SHA=%s\r\n' "$TEST_SHA" >"$TEST_PIN_FILE"
    load_pin
    assert_eq "$FORK_SHA" "$TEST_SHA"
    assert_eq "$FORK_URL" https://github.com/test/libfprint.git
}

test_check_private_path_allows_a_private_group() {
    lib
    mkdir -p "$DGL_WORK_DIR/build"
    chmod g+w "$DGL_WORK_DIR/build"
    echo "me:x:$(id -g):" >"$FAKE/group"
    check_private_path "$DGL_WORK_DIR/build"
}

test_check_private_path_rejects_a_group_with_members() {
    lib
    mkdir -p "$DGL_WORK_DIR/build"
    chmod g+w "$DGL_WORK_DIR/build"
    echo "me:x:$(id -g):mallory" >"$FAKE/group"
    assert_fails_with "chmod go-w" check_private_path "$DGL_WORK_DIR/build"
}

test_check_private_path_rejects_a_group_named_differently() {
    lib
    mkdir -p "$DGL_WORK_DIR/build"
    chmod g+w "$DGL_WORK_DIR/build"
    echo "devs:x:$(id -g):" >"$FAKE/group"
    assert_fails_with "writable by group" check_private_path "$DGL_WORK_DIR/build"
}

test_check_secure_path_never_allows_group_write() {
    lib
    mkdir -p "$ROOT/opt/a"
    chmod g+w "$ROOT/opt/a"
    echo "me:x:$(id -g):" >"$FAKE/group"
    assert_fails_with "writable by group or others" check_secure_path "$ROOT/opt/a"
}

test_check_symbols_fails_when_fprintd_cannot_be_read() {
    lib
    fake_build
    assert_fails_with "cannot read" check_symbols "$DGL_WORK_DIR/build/libfprint/libfprint-2.so.2.0.0" "$ROOT/nonexistent"
}

test_check_symbols_fails_when_fprintd_imports_nothing() {
    lib
    fake_build
    : >"$ROOT/usr/libexec/fprintd"
    assert_fails_with "imports no libfprint functions" \
        check_symbols "$DGL_WORK_DIR/build/libfprint/libfprint-2.so.2.0.0" "$ROOT/usr/libexec/fprintd"
}

test_check_private_path_rejects_a_group_that_is_someone_elses_primary_group() {
    lib
    mkdir -p "$DGL_WORK_DIR/build"
    chmod g+w "$DGL_WORK_DIR/build"
    echo "me:x:$(id -g):" >"$FAKE/group"
    # useradd -g me bob: bob is not listed in the group, but can write.
    echo "bob:x:4242:$(id -g)::/home/bob:/bin/bash" >"$FAKE/passwd"
    assert_fails_with "writable by group" check_private_path "$DGL_WORK_DIR/build"
}
