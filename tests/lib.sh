#!/usr/bin/env bash
# Shared helpers for the test harness. Source this file; do not execute it.
# Portable: bash 3.2 (macOS /bin/bash) and the GNU/BSD userland on macOS and ubuntu-latest.
# shellcheck shell=bash

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FAILURES=0

# Read a Makefile variable so the Makefile stays the single source of truth for versions.
mkvar() { make -s -C "$REPO_ROOT" "print-$1"; }

log()  { printf '==> %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

# An optional dependency is missing: skip locally, fail in CI where every check must run.
skip() {
  if [ -n "${CI:-}" ]; then
    printf 'FAIL: %s (required in CI)\n' "$*" >&2
    exit 1
  fi
  printf 'SKIP: %s\n' "$*"
}

have() { command -v "$1" >/dev/null 2>&1; }
need() {
  local t
  for t in "$@"; do
    have "$t" || { printf 'missing required tool: %s\n' "$t" >&2; exit 1; }
  done
}

# check DESCRIPTION COMMAND [ARGS...]: PASS when the command succeeds; FAIL (with the
# command output) otherwise.
check() {
  local desc=$1 out
  shift
  if out=$("$@" 2>&1); then
    pass "$desc"
  else
    fail "$desc"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
}

# wait_for SECONDS COMMAND [ARGS...]: retry every 5s until success or the budget is spent.
wait_for() {
  local budget=$1 start=$SECONDS
  shift
  until "$@" >/dev/null 2>&1; do
    [ $((SECONDS - start)) -lt "$budget" ] || return 1
    sleep 5
  done
}

# Print the first running container runtime (docker, then podman), or fail.
container_runtime() {
  local rt
  for rt in docker podman; do
    if have "$rt" && "$rt" info >/dev/null 2>&1; then
      printf '%s\n' "$rt"
      return 0
    fi
  done
  return 1
}

# summary NAME: exit non-zero if any check failed.
summary() {
  if [ "$FAILURES" -gt 0 ]; then
    printf '%s: %d check(s) failed\n' "$1" "$FAILURES" >&2
    exit 1
  fi
  printf '%s: all checks passed\n' "$1"
}
