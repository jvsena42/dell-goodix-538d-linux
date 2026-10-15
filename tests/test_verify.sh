# shellcheck shell=bash
# scripts/verify.sh

installed() {
    fake_build
    probe_passed
    run_script install.sh >/dev/null 2>&1
}

test_verify_passes_after_install() {
    installed
    run_script verify.sh
}

test_verify_detects_a_modified_library() {
    installed
    echo tampered >>"$ROOT/opt/dell-goodix-538d/lib/libfprint-2.so.2.0.0"
    assert_fails_with "do not match MANIFEST" run_script verify.sh
}

test_verify_detects_a_modified_dropin() {
    installed
    echo "Environment=LD_PRELOAD=/tmp/x.so" >>"$ROOT/etc/systemd/system/fprintd.service.d/10-dell-goodix-538d.conf"
    assert_fails_with "has been changed" run_script verify.sh
}

test_verify_detects_an_fprintd_upgrade_that_needs_new_symbols() {
    installed
    fake_symbols "$ROOT/usr/libexec/fprintd" UND fp_context_new fp_device_open fp_device_verify fp_device_new_api
    assert_fails_with "fp_device_new_api" run_script verify.sh
}

test_verify_detects_fprintd_not_using_our_library() {
    installed
    touch "$FAKE/ignore-dropin"
    assert_fails_with "running without" run_script verify.sh
}

test_verify_says_when_not_installed() {
    assert_fails_with "not installed" run_script verify.sh
}

test_verify_detects_a_retargeted_symlink() {
    installed
    ln -sfn ../PIN "$ROOT/opt/dell-goodix-538d/lib/libfprint-2.so.2"
    assert_fails_with "does not point at" run_script verify.sh
}

# Review repro: content matches, but the installed library is world-writable.
test_verify_detects_a_writable_installed_library() {
    installed
    chmod 666 "$ROOT/opt/dell-goodix-538d/lib/libfprint-2.so.2.0.0"
    assert_fails_with "writable by group or others" run_script verify.sh
}

test_verify_detects_a_writable_manifest() {
    installed
    chmod 666 "$ROOT/opt/dell-goodix-538d/MANIFEST"
    assert_fails_with "writable by group or others" run_script verify.sh
}

# fprintd's LD_LIBRARY_PATH points here: any extra library would be loaded.
test_verify_detects_an_extra_file_in_lib() {
    installed
    echo x >"$ROOT/opt/dell-goodix-538d/lib/libglib-2.0.so.0"
    assert_fails_with "libglib-2.0.so.0" run_script verify.sh
}
