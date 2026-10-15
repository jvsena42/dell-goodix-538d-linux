# shellcheck shell=bash
# tests/run.sh itself, on a copy with planted test files.

runner_copy() {
    mkdir -p "$TMP/copy/tests"
    cp "$REPO/tests/run.sh" "$REPO/tests/helpers.sh" "$TMP/copy/tests/"
}

test_runner_fails_when_a_test_file_does_not_load() {
    runner_copy
    printf 'test_before() { true; }\nif then\ntest_after() { false; }\n' >"$TMP/copy/tests/test_broken.sh"
    assert_fails_with "test_broken.sh could not be loaded" "$TMP/copy/tests/run.sh"
}

test_runner_reports_failing_tests() {
    runner_copy
    printf 'test_fails() { false; }\n' >"$TMP/copy/tests/test_one.sh"
    assert_fails_with "1 failed" "$TMP/copy/tests/run.sh"
}

test_runner_passes_a_good_file() {
    runner_copy
    printf 'test_passes() { true; }\n' >"$TMP/copy/tests/test_one.sh"
    "$TMP/copy/tests/run.sh" >/dev/null
}
