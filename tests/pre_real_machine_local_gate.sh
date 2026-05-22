#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok(){ printf 'OK: %s\n' "$*"; }

if [[ -n "$(git status --porcelain)" ]]; then
  git status --short >&2
  fail "working tree must be clean before real-machine testing"
fi
ok "clean working tree"

git diff --check
ok "diff whitespace"

bash -n install_transit.sh
bash -n install_landing.sh
bash -n tests/local_static_invariants.sh
bash -n tests/ssh_hostkey_probe.sh
ok "bash syntax"

git ls-files --eol \
  | awk '$1!="i/lf" || $2!="w/lf" {bad=1; print} END {exit bad ? 1 : 0}' \
  || fail "tracked files must be LF"
ok "LF endings"

bash tests/local_static_invariants.sh
ok "local static invariants"
