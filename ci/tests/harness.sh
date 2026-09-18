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

ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

summary() {  # summary <label>
  if [ "$fails" -ne 0 ]; then printf '\n%d %s test(s) FAILED\n' "$fails" "$1"; exit 1; fi
  printf '\nAll %s tests passed.\n' "$1"
}
