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
    cp "$ROOT/opt/dell-goodix-538d/lib/libfprint-2.so.2.0.0" "$ROOT/opt/dell-goodix-538d/lib/other.so"
    ln -sfn other.so "$ROOT/opt/dell-goodix-538d/lib/libfprint-2.so.2"
    assert_fails_with "does not point at" run_script verify.sh
}
