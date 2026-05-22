#!/usr/bin/env bash
set -euo pipefail

if (( "$#" == 0 )); then
  set -- 38.59.243.23 47.251.82.237
fi

command -v ssh-keyscan >/dev/null 2>&1 || {
  echo "ssh-keyscan not found" >&2
  exit 1
}
command -v ssh-keygen >/dev/null 2>&1 || {
  echo "ssh-keygen not found" >&2
  exit 1
}

for host in "$@"; do
  case "$host" in
    *[!0-9.]*|'') echo "skip invalid IPv4 host: $host" >&2; continue ;;
  esac
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  if ! ssh-keyscan -T 8 -t ed25519,rsa "$host" >"$tmp" 2>/dev/null; then
    echo "failed to scan: $host" >&2
    rm -f "$tmp"
    trap - EXIT
    continue
  fi
  if [[ ! -s "$tmp" ]]; then
    echo "no host key returned: $host" >&2
    rm -f "$tmp"
    trap - EXIT
    continue
  fi
  echo "== $host =="
  ssh-keygen -lf "$tmp"
  rm -f "$tmp"
  trap - EXIT
done
