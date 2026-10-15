# shellcheck shell=bash
# scripts/uninstall.sh

installed() {
    fake_build
    probe_passed
    run_script install.sh >/dev/null 2>&1
}

test_uninstall_removes_everything_we_added() {
    installed
    echo calibration >"$ROOT/var/lib/fprint/goodixtls53xd-fpn.bin"
    run_script uninstall.sh
    assert_no_file "$ROOT/opt/dell-goodix-538d"
    assert_no_file "$ROOT/etc/systemd/system/fprintd.service.d"
    assert_no_file "$ROOT/var/lib/fprint/goodixtls53xd-fpn.bin"
    assert_contains "$FAKE/systemctl.log" "daemon-reload"
    assert_contains "$FAKE/systemctl.log" "try-restart fprintd.service"
}

test_uninstall_brings_fprintd_back_to_the_stock_library() {
    installed
    run_script uninstall.sh
    assert_contains "$ROOT/proc/4242/maps" "/usr/lib/x86_64-linux-gnu/libfprint-2.so.2"
}

test_uninstall_twice_is_a_no_op() {
    installed
    run_script uninstall.sh
    : >"$FAKE/systemctl.log"
    local out
    out=$(run_script uninstall.sh 2>&1)
    [[ $out == *"Nothing to uninstall"* ]] || fail "second run said: $out"
    assert_eq "$(cat "$FAKE/systemctl.log")" ""
}

test_uninstall_keeps_other_dropins() {
    installed
    echo "[Service]" >"$ROOT/etc/systemd/system/fprintd.service.d/50-mine.conf"
    run_script uninstall.sh
    assert_file "$ROOT/etc/systemd/system/fprintd.service.d/50-mine.conf"
}

test_uninstall_keeps_user_fingerprints() {
    installed
    mkdir -p "$ROOT/var/lib/fprint/joao"
    echo print >"$ROOT/var/lib/fprint/joao/print"
    run_script uninstall.sh
    assert_file "$ROOT/var/lib/fprint/joao/print"
}

test_uninstall_refuses_a_foreign_dropin() {
    mkdir -p "$ROOT/etc/systemd/system/fprintd.service.d"
    echo "[Service]" >"$ROOT/etc/systemd/system/fprintd.service.d/10-dell-goodix-538d.conf"
    assert_fails_with "not written by this project" run_script uninstall.sh
    assert_file "$ROOT/etc/systemd/system/fprintd.service.d/10-dell-goodix-538d.conf"
}

test_uninstall_refuses_a_foreign_prefix() {
    mkdir -p "$ROOT/opt/dell-goodix-538d"
    echo "someone else's" >"$ROOT/opt/dell-goodix-538d/notes.txt"
    assert_fails_with "not created by this project" run_script uninstall.sh
    assert_file "$ROOT/opt/dell-goodix-538d/notes.txt"
}

test_uninstall_removes_leftovers_from_an_interrupted_install() {
    installed
    cp -a "$ROOT/opt/dell-goodix-538d" "$ROOT/opt/dell-goodix-538d.old"
    run_script uninstall.sh
    assert_no_file "$ROOT/opt/dell-goodix-538d.old"
}

test_uninstall_reloads_systemd_before_removing_the_library() {
    installed
    : >"$FAKE/systemctl.log"
    run_script uninstall.sh
    assert_eq "$(head -n 1 "$FAKE/systemctl.log")" "daemon-reload"
}

# Review repro: install killed after staging lib/ and PIN, before MANIFEST.
test_uninstall_cleans_up_a_staging_dir_from_a_killed_install() {
    installed
    local staging=$ROOT/opt/dell-goodix-538d.new
    mkdir -p "$staging/lib"
    cp "$ROOT/opt/dell-goodix-538d/lib/libfprint-2.so.2.0.0" "$staging/lib/"
    ln -s libfprint-2.so.2.0.0 "$staging/lib/libfprint-2.so.2"
    cp "$TEST_PIN_FILE" "$staging/PIN"
    run_script uninstall.sh
    assert_no_file "$staging"
    assert_no_file "$ROOT/opt/dell-goodix-538d"
    assert_contains "$FAKE/systemctl.log" "try-restart fprintd.service"
}

test_uninstall_refuses_a_foreign_leftover_before_changing_anything() {
    installed
    mkdir -p "$ROOT/opt/dell-goodix-538d.old"
    echo "my backup" >"$ROOT/opt/dell-goodix-538d.old/notes.txt"
    assert_fails_with "not created by this project" run_script uninstall.sh
    assert_file "$ROOT/etc/systemd/system/fprintd.service.d/10-dell-goodix-538d.conf"
    assert_file "$ROOT/opt/dell-goodix-538d/MANIFEST"
}
