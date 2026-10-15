# shellcheck shell=bash
# scripts/build.sh, with fake meson and ninja.

pinned_checkout() {
    local src=$DGL_WORK_DIR/src
    git init -q "$src"
    git -C "$src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m pinned
    write_pin https://github.com/test/libfprint.git "$(git -C "$src" rev-parse HEAD)"
}

test_build_uses_default_drivers_and_never_downloads() {
    pinned_checkout
    run_script build.sh
    assert_contains "$FAKE/meson.log" "-Ddrivers=default"
    assert_contains "$FAKE/meson.log" "--wrap-mode=nodownload"
    assert_contains "$FAKE/meson.log" "--prefix=/opt/dell-goodix-538d"
    assert_contains "$FAKE/meson.log" "-Dudev_rules=disabled"
    assert_contains "$FAKE/meson.log" "$DGL_WORK_DIR/build "
}

test_test_build_adds_virtual_drivers_in_its_own_dir() {
    pinned_checkout
    run_script build.sh --test-build
    assert_contains "$FAKE/meson.log" "-Ddrivers=all"
    assert_contains "$FAKE/meson.log" "$DGL_WORK_DIR/build-test "
}

test_build_refuses_root() {
    pinned_checkout
    TEST_UID=0 assert_fails_with "do not build as root" run_script build.sh
    assert_no_file "$FAKE/meson.log"
}

test_build_allows_root_when_ci_says_so() {
    pinned_checkout
    local out
    # The sandbox tree belongs to the real user, so a root build may still be
    # refused by the ownership check; only the root guard itself must not fire.
    out=$(TEST_UID=0 ALLOW_ROOT_BUILD=1 run_script build.sh 2>&1) || true
    [[ $out != *"do not build as root"* ]] || fail "ALLOW_ROOT_BUILD=1 was ignored: $out"
}

test_build_refuses_an_unpinned_checkout() {
    pinned_checkout
    git -C "$DGL_WORK_DIR/src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m drift
    assert_fails_with "pin mismatch" run_script build.sh
    assert_no_file "$FAKE/meson.log"
}

test_build_rejects_unknown_options() {
    assert_fails_with "usage" run_script build.sh --drivers=all
}

test_build_stamps_the_commit_and_library() {
    pinned_checkout
    run_script build.sh
    local sha
    sha=$(git -C "$DGL_WORK_DIR/src" rev-parse HEAD)
    assert_eq "$(cat "$DGL_WORK_DIR/build/BUILT_FROM")" "$sha $(lib_sum_of "$DGL_WORK_DIR/build")"
}

lib_sum_of() {
    sha256sum "$(readlink -f "$1/libfprint/libfprint-2.so.2")" | cut -d' ' -f1
}

test_build_refuses_a_build_dir_others_can_write() {
    pinned_checkout
    mkdir -p "$DGL_WORK_DIR/build"
    chmod o+w "$DGL_WORK_DIR/build"
    assert_fails_with "writable by group or others" run_script build.sh
    assert_no_file "$FAKE/meson.log"
}

test_build_refuses_a_source_tree_with_an_acl() {
    pinned_checkout
    setfacl -m u:nobody:rwx "$DGL_WORK_DIR/src"
    assert_fails_with "has an ACL" run_script build.sh
    assert_no_file "$FAKE/meson.log"
}

# The attack from review: core.fsmonitor planted through a writable .git/config.
test_build_checks_the_source_tree_before_running_git() {
    pinned_checkout
    printf '#!/bin/sh\ntouch %s/pwned\n' "$TMP" >"$TMP/evil"
    chmod +x "$TMP/evil"
    git -C "$DGL_WORK_DIR/src" config core.fsmonitor "$TMP/evil"
    chmod 666 "$DGL_WORK_DIR/src/.git/config"
    assert_fails_with "writable by group or others" run_script build.sh
    assert_no_file "$TMP/pwned"
    assert_no_file "$FAKE/meson.log"
}

test_build_never_runs_fsmonitor_even_in_a_private_tree() {
    pinned_checkout
    printf '#!/bin/sh\ntouch %s/pwned\n' "$TMP" >"$TMP/evil"
    chmod +x "$TMP/evil"
    git -C "$DGL_WORK_DIR/src" config core.fsmonitor "$TMP/evil"
    rm -f "$TMP/pwned"
    run_script build.sh
    assert_no_file "$TMP/pwned"
}

test_build_checks_an_existing_build_tree_before_meson() {
    pinned_checkout
    mkdir -p "$DGL_WORK_DIR/build"
    echo "rule evil" >"$DGL_WORK_DIR/build/build.ninja"
    chmod 666 "$DGL_WORK_DIR/build/build.ninja"
    assert_fails_with "build.ninja is writable by group or others" run_script build.sh
    assert_no_file "$FAKE/meson.log"
}
