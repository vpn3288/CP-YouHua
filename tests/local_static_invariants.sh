#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok(){ printf 'OK: %s\n' "$*"; }

[[ -f install_transit.sh ]] || fail "install_transit.sh missing"
[[ -f install_landing.sh ]] || fail "install_landing.sh missing"

bash -n install_transit.sh
bash -n install_landing.sh
ok "bash syntax"

git ls-files --eol install_transit.sh install_landing.sh README.md JiLu.md guides/main_writer_task_guide.md guides/reviewer_task_guide.md \
  | awk '$1!="i/lf" || $2!="w/lf" {bad=1; print} END {exit bad ? 1 : 0}' \
  || fail "tracked text files must be LF"
ok "LF endings"

if git grep -IlE 'ghp_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|cfat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{20,}|BEGIN (RSA|OPENSSH|EC|PRIVATE) KEY' -- . ':!tests/local_static_invariants.sh' >/tmp/cp-youhua-secret-scan.$$ 2>/dev/null; then
  sed 's/^/secret-like literal in: /' /tmp/cp-youhua-secret-scan.$$ >&2
  rm -f /tmp/cp-youhua-secret-scan.$$
  fail "secret-like literal found"
fi
rm -f /tmp/cp-youhua-secret-scan.$$
ok "secret scan"

valid_token=$(
  printf '%s' '{"ip":"1.2.3.4","dom":"example.com","port":443,"uuid":"11111111-1111-4111-8111-111111111111","pwd":"abcdefghijklmnop","pfx":"abc"}' \
    | base64 | tr -d '\n'
)
bash -c 'source <(sed "\$d" install_transit.sh); extract_import_token_json_no_deps "$1" | grep -q "\"dom\":\"example.com\""' _ "$valid_token" \
  || fail "valid import token pre-parse failed"
if bash -c 'source <(sed "\$d" install_transit.sh); extract_import_token_json_no_deps "$1" >/dev/null' _ 'eyJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' 2>/dev/null; then
  fail "invalid base64-like token passed pre-parse"
fi
ok "transit token pre-parse"

python3 - <<'PY'
import re
from pathlib import Path

root = Path(".")
transit = (root / "install_transit.sh").read_text(encoding="utf-8")
landing = (root / "install_landing.sh").read_text(encoding="utf-8")
readme = (root / "README.md").read_text(encoding="utf-8")

def die(msg: str) -> None:
    raise SystemExit(f"FAIL: {msg}")

def version(text: str, name: str) -> str:
    m = re.search(r'^readonly VERSION="(v[0-9]+\.[0-9]+)"$', text, re.M)
    if not m:
        die(f"{name} VERSION missing")
    return m.group(1)

tv, lv = version(transit, "transit"), version(landing, "landing")
if tv != lv:
    die(f"version mismatch: {tv} != {lv}")
if f"当前版本：`{tv}`" not in readme:
    die("README current version mismatch")
if f"install_transit_{tv}.sh" not in transit:
    die("transit header version mismatch")
if f"install_landing_{lv}.sh" not in landing:
    die("landing header version mismatch")

def between(text: str, start: str, end: str, name: str) -> str:
    i = text.find(start)
    if i < 0:
        die(f"{name}: start marker missing: {start}")
    j = text.find(end, i + len(start))
    if j < 0:
        die(f"{name}: end marker missing: {end}")
    return text[i:j]

main_import = between(transit, 'if [[ "${1:-}" == "--import" ]]; then', 'if [[ "${1:-}" == "--status" ]]', "transit main import")
if main_import.find('extract_import_token_json_no_deps "${2:-}" >/dev/null') < 0:
    die("transit --import does not parse token before lock")
if main_import.find('extract_import_token_json_no_deps "${2:-}" >/dev/null') > main_import.find('_acquire_lock; import_token'):
    die("transit --import token parse is after lock/import")

import_body = between(transit, 'import_token(){', 'local ip=""', "transit import_token")
if import_body.find('extract_import_token_json_no_deps "$raw"') < 0:
    die("import_token does not parse token before dependencies")
if import_body.find('extract_import_token_json_no_deps "$raw"') > import_body.find('check_deps'):
    die("import_token calls check_deps before token parse")

fresh_preflight = between(transit, 'fresh_install(){', 'check_deps', "transit fresh preflight")
if fresh_preflight.find('extract_import_token_json_no_deps "$LANDING_TOKEN" >/dev/null') < 0:
    die("fresh_install does not pre-parse LANDING_TOKEN")

headless_ip = between(landing, 'if [[ -n "${FAKE_IP:-}" ]]; then', 'info "检测到无头静默安装模式', "landing headless IP")
if 'die "FAKE_IP' not in headless_ip:
    die("FAKE_IP is not rejected in headless mode")
if headless_ip.find('die "FAKE_IP') > headless_ip.find('LANDING_AUTO_PUBLIC_IP'):
    die("FAKE_IP rejection must happen before public IP assignment")

purge_nginx = between(landing, 'if (( _nginx_installed_by_script )); then', 'rm -rf "$MANAGER_BASE"', "purge_all nginx cleanup")
if purge_nginx.find('systemctl reload nginx') > purge_nginx.find('restore_packaged_nginx_default_site'):
    die("purge_all restores Debian default site before nginx reload")

rollback_nginx = between(landing, 'elif systemctl is-active --quiet nginx 2>/dev/null; then', 'systemctl reset-failed nginx', "fresh rollback nginx cleanup")
if 'systemctl restart nginx' in rollback_nginx:
    die("fresh rollback must not restart user-owned nginx after default-site restore")
if rollback_nginx.find('systemctl reload nginx') > rollback_nginx.find('restore_packaged_nginx_default_site'):
    die("fresh rollback restores Debian default site before nginx reload")

deleting_block = between(landing, 'name "*.conf.deleting"', '# [v2.9', "landing deleting recovery")
if deleting_block.find('_acquire_lock') < 0 or deleting_block.find('_release_lock') < 0:
    die(".conf.deleting recovery is not lock guarded")

service_recovery = between(landing, 'warn "服务未运行，尝试自动恢复..."', 'if (( _recovered == 0 )); then', "landing service recovery")
if service_recovery.find('_acquire_lock') > service_recovery.find('sync_xray_config'):
    die("service recovery sync happens before lock")
if service_recovery.find('_release_lock') < service_recovery.find('systemctl restart "$LANDING_SVC"'):
    die("service recovery releases lock before restart attempt")

collision = between(landing, 'if [[ -f "$_node_conf" ]]; then', 'mv -f "$_tmp_node" "$_node_conf"', "add_node collision")
if '_cancel_add_node_before_trap "节点文件名碰撞' not in collision:
    die("add_node collision does not use cert-cleaning cancel path")

print(f"OK: static invariants for {tv}")
PY
