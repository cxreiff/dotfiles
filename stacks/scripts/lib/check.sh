#!/usr/bin/env bash
# stacks/scripts/lib/check.sh
# Shared check helpers for `dotfiles stacks doctor`. Source-only — do not execute.
#
# Contract:
#   pass "msg"  -> "[OK]   msg"
#   warn "msg"  -> "[WARN] msg"  + sets __check_warned=1
#   fail "msg"  -> "[FAIL] msg"  + sets __check_failed=1
# Caller decides exit status by inspecting $__check_failed at end of run.

__check_failed=0
__check_warned=0

pass() { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; __check_warned=1; }
fail() { printf '[FAIL] %s\n' "$*"; __check_failed=1; }
