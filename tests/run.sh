#!/usr/bin/env bash
# Plain-bash test runner, no dependencies. Every tests/test_*.sh file defines
# test_* functions; each one runs in its own process and its own sandbox, so
# nothing here touches the real system.
#
# Usage: tests/run.sh [file-or-test-name-filter]

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

filter=${1:-}
passed=0
failed=0
failures=()

for file in tests/test_*.sh; do
    # A test file that fails to load (syntax error, failing top-level command)
    # would silently drop every test after the failure, so count it as a
    # failure instead.
    if ! names=$(bash -c 'set -e; source tests/helpers.sh; source "$1"; declare -F' _ "$file" |
        awk '$3 ~ /^test_/ { print $3 }'); then
        failed=$((failed + 1))
        failures+=("$file")
        printf 'FAIL  %s could not be loaded\n' "$file"
        continue
    fi
    for name in $names; do
        [ -z "$filter" ] || [[ $file == *"$filter"* ]] || [[ $name == *"$filter"* ]] || continue
        if output=$(bash -c "source tests/helpers.sh; source '$file'; setup_sandbox; trap teardown_sandbox EXIT; set -e; $name" 2>&1); then
            passed=$((passed + 1))
            printf 'ok    %s\n' "$name"
        else
            failed=$((failed + 1))
            failures+=("$name")
            printf 'FAIL  %s\n' "$name"
            printf '%s\n' "$output" | sed 's/^/      /'
        fi
    done
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" = 0 ] || { printf 'failed: %s\n' "${failures[*]}"; exit 1; }
