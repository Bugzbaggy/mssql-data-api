#!/usr/bin/env bash
# Shared expect-pass/expect-fail runner for the test scripts in this directory.
fails=0

expect() {  # expect <pass|fail> <description> <command...>
  local want="$1" desc="$2"; shift 2
  local got
  if "$@" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    printf 'ok   (%s) %s\n' "$want" "$desc"
  else
    printf 'FAIL expected=%s actual=%s -- %s\n' "$want" "$got" "$desc"
    fails=$((fails + 1))
  fi
}

# A negative must fail for the RIGHT reason: the gates exit 1 on a finding and 2 on a missing file
# or bad arguments, so a broken fixture that "fails" with rc=2 would otherwise pass as a negative.
expect_rc() {  # expect_rc <exit code> <description> <command...>
  local want="$1" desc="$2"; shift 2
  local got
  "$@" >/dev/null 2>&1; got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'ok   (rc=%s) %s\n' "$want" "$desc"
  else
    printf 'FAIL expected rc=%s actual rc=%s -- %s\n' "$want" "$got" "$desc"
    fails=$((fails + 1))
  fi
}

ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

summary() {  # summary <label>
  if [ "$fails" -ne 0 ]; then printf '\n%d %s test(s) FAILED\n' "$fails" "$1"; exit 1; fi
  printf '\nAll %s tests passed.\n' "$1"
}
