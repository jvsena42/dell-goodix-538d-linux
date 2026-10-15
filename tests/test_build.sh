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
    TEST_UID=0 ALLOW_ROOT_BUILD=1 run_script build.sh
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
