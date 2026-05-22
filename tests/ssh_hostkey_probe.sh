#!/usr/bin/env bash
set -euo pipefail

if (( "$#" == 0 )); then
  if [[ -n "${SSH_HOSTKEY_PROBE_HOSTS:-}" ]]; then
    # shellcheck disable=SC2206
    set -- ${SSH_HOSTKEY_PROBE_HOSTS}
  else
    echo "usage: bash tests/ssh_hostkey_probe.sh <ipv4>[:port][=SHA256:fingerprint] ..." >&2
    echo "or set SSH_HOSTKEY_PROBE_HOSTS with the same space-separated arguments" >&2
    exit 2
  fi
fi

command -v ssh-keyscan >/dev/null 2>&1 || {
  echo "ssh-keyscan not found" >&2
  exit 1
}
command -v ssh-keygen >/dev/null 2>&1 || {
  echo "ssh-keygen not found" >&2
  exit 1
}

rc=0
for spec in "$@"; do
  host="${spec%%=*}"
  expected=""
  [[ "$spec" == *=* ]] && expected="${spec#*=}"
  port="22"
  if [[ "$host" == *:* ]]; then
    port="${host##*:}"
    host="${host%:*}"
  fi
  case "$host" in
    *[!0-9.]*|'') echo "skip invalid IPv4 host: $host" >&2; continue ;;
  esac
  case "$port" in
    *[!0-9]*|'') echo "skip invalid SSH port: $port" >&2; continue ;;
  esac
  if (( 10#$port < 1 || 10#$port > 65535 )); then
    echo "skip invalid SSH port: $port" >&2
    continue
  fi
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  if ! ssh-keyscan -T 8 -p "$port" -t ed25519,rsa "$host" >"$tmp" 2>/dev/null; then
    echo "failed to scan: $host:$port" >&2
    rm -f "$tmp"
    trap - EXIT
    continue
  fi
  if [[ ! -s "$tmp" ]]; then
    echo "no host key returned: $host:$port" >&2
    rm -f "$tmp"
    trap - EXIT
    continue
  fi
  echo "== $host:$port =="
  fingerprints="$(ssh-keygen -lf "$tmp")"
  printf '%s\n' "$fingerprints"
  if [[ -n "$expected" ]]; then
    if printf '%s\n' "$fingerprints" | grep -Fq "$expected"; then
      echo "match: $host:$port $expected"
    else
      echo "mismatch: $host:$port expected $expected" >&2
      rc=1
    fi
  fi
  rm -f "$tmp"
  trap - EXIT
done
exit "$rc"
