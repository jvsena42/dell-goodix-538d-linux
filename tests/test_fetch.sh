# shellcheck shell=bash
# scripts/fetch.sh, against a local git repository standing in for GitHub.

URL=https://github.com/test/libfprint.git

make_fork() {
    local fork=$TMP/fork
    git init -q "$fork"
    git -C "$fork" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
    git -C "$fork" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
    # Route the GitHub URL to the local repository.
    export GIT_CONFIG_GLOBAL=$TMP/gitconfig
    git config --global url."file://$fork".insteadOf "$URL"
    FIRST=$(git -C "$fork" rev-parse HEAD~1)
}

test_fetch_checks_out_the_pinned_commit() {
    make_fork
    write_pin "$URL" "$FIRST"
    run_script fetch.sh
    assert_eq "$(git -C "$DGL_WORK_DIR/src" rev-parse HEAD)" "$FIRST"
}

test_fetch_is_repeatable() {
    make_fork
    write_pin "$URL" "$FIRST"
    run_script fetch.sh
    run_script fetch.sh
    assert_eq "$(git -C "$DGL_WORK_DIR/src" rev-parse HEAD)" "$FIRST"
}

test_fetch_rejects_a_commit_that_does_not_exist() {
    make_fork
    write_pin "$URL" "$TEST_SHA"
    assert_fails_with "" run_script fetch.sh
}

test_fetch_rejects_a_checkout_from_another_remote() {
    make_fork
    write_pin "$URL" "$FIRST"
    run_script fetch.sh
    git -C "$DGL_WORK_DIR/src" remote set-url origin https://github.com/evil/libfprint.git
    assert_fails_with "not $URL" run_script fetch.sh
}

test_verify_checkout_rejects_local_changes() {
    make_fork
    write_pin "$URL" "$FIRST"
    run_script fetch.sh
    echo tampered >"$DGL_WORK_DIR/src/extra.c"
    source "$REPO/lib/common.sh"
    assert_fails_with "local changes" verify_checkout "$DGL_WORK_DIR/src" "$FIRST"
}

test_verify_checkout_rejects_the_wrong_commit() {
    make_fork
    write_pin "$URL" "$FIRST"
    run_script fetch.sh
    git -C "$DGL_WORK_DIR/src" -c advice.detachedHead=false checkout -q "$(git -C "$TMP/fork" rev-parse HEAD)"
    source "$REPO/lib/common.sh"
    assert_fails_with "pin mismatch" verify_checkout "$DGL_WORK_DIR/src" "$FIRST"
}

test_fetch_rejects_a_commit_with_submodules() {
    make_fork
    printf '[submodule "x"]\n' >"$TMP/fork/.gitmodules"
    git -C "$TMP/fork" add .gitmodules
    git -C "$TMP/fork" -c user.name=t -c user.email=t@t commit -q -m submodules
    write_pin "$URL" "$(git -C "$TMP/fork" rev-parse HEAD)"
    assert_fails_with "submodules or meson subprojects" run_script fetch.sh
}

test_fetch_refuses_a_work_dir_others_can_write_before_cloning() {
    make_fork
    write_pin "$URL" "$FIRST"
    chmod o+w "$DGL_WORK_DIR"
    assert_fails_with "writable by group or others" run_script fetch.sh
    assert_no_file "$DGL_WORK_DIR/src"
}
