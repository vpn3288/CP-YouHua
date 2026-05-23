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

git ls-files --eol install_transit.sh install_landing.sh README.md JiLu.md guides/main_writer_task_guide.md guides/reviewer_task_guide.md tests/local_static_invariants.sh tests/ssh_hostkey_probe.sh tests/pre_real_machine_local_gate.sh \
  | awk '$1!="i/lf" || $2!="w/lf" {bad=1; print} END {exit bad ? 1 : 0}' \
  || fail "tracked text files must be LF"
ok "LF endings"

if git grep -IlE 'ghp_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|cfat_[A-Za-z0-9_]+|cfut_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{20,}|BEGIN (RSA|OPENSSH|EC|PRIVATE) KEY' -- . ':!tests/local_static_invariants.sh' >/tmp/cp-youhua-secret-scan.$$ 2>/dev/null; then
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
extractor_tmp="$(mktemp)"
trap 'rm -f "$extractor_tmp"' EXIT
{
  printf '%s\n' 'die(){ printf "%s\n" "$*" >&2; exit 1; }'
  printf '%s\n' 'trim(){ local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf "%s" "$s"; }'
  awk '/^normalize_import_token_no_deps\(\)/{p=1} p{print} p && /^extract_import_token_json_no_deps\(\)/{in_extract=1} in_extract && /^}/{exit}' install_transit.sh
} >"$extractor_tmp"
bash -c 'source "$1"; extract_import_token_json_no_deps "$2" | grep -q "\"dom\":\"example.com\""' _ "$extractor_tmp" "$valid_token" \
  || fail "valid import token pre-parse failed"
bash -c 'source "$1"; extract_import_token_json_no_deps "$2" | grep -q "\"dom\":\"example.com\""' _ "$extractor_tmp" "bash install_transit.sh --import $valid_token" \
  || fail "full import command token pre-parse failed"
if bash -c 'source "$1"; extract_import_token_json_no_deps "$2" >/dev/null' _ "$extractor_tmp" 'eyJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' 2>/dev/null; then
  fail "invalid base64-like token passed pre-parse"
fi
malformed_token=$(printf '%s' '{"ip":,"dom":"example.com"}' | base64 | tr -d '\n')
if bash -c 'source "$1"; extract_import_token_json_no_deps "$2" >/dev/null' _ "$extractor_tmp" "$malformed_token" 2>/dev/null; then
  fail "malformed JSON token passed pre-parse"
fi
bad_ip_token=$(printf '%s' '{"ip":"999.2.3.4","dom":"example.com","port":443,"uuid":"11111111-1111-4111-8111-111111111111","pwd":"abcdefghijklmnop","pfx":"abc"}' | base64 | tr -d '\n')
if bash -c 'source "$1"; extract_import_token_json_no_deps "$2" >/dev/null' _ "$extractor_tmp" "$bad_ip_token" 2>/dev/null; then
  fail "semantic invalid IP token passed pre-parse"
fi
private_ip_token=$(printf '%s' '{"ip":"10.0.0.1","dom":"example.com","port":443,"uuid":"11111111-1111-4111-8111-111111111111","pwd":"abcdefghijklmnop","pfx":"abc"}' | base64 | tr -d '\n')
if bash -c 'source "$1"; extract_import_token_json_no_deps "$2" >/dev/null' _ "$extractor_tmp" "$private_ip_token" 2>/dev/null; then
  fail "private IP token passed pre-parse"
fi
bad_uuid_token=$(printf '%s' '{"ip":"1.2.3.4","dom":"example.com","port":443,"uuid":"bad","pwd":"abcdefghijklmnop","pfx":"abc"}' | base64 | tr -d '\n')
if bash -c 'source "$1"; extract_import_token_json_no_deps "$2" >/dev/null' _ "$extractor_tmp" "$bad_uuid_token" 2>/dev/null; then
  fail "semantic invalid UUID token passed pre-parse"
fi
short_pwd_token=$(printf '%s' '{"ip":"1.2.3.4","dom":"example.com","port":443,"uuid":"11111111-1111-4111-8111-111111111111","pwd":"short","pfx":"abc"}' | base64 | tr -d '\n')
if bash -c 'source "$1"; extract_import_token_json_no_deps "$2" >/dev/null' _ "$extractor_tmp" "$short_pwd_token" 2>/dev/null; then
  fail "semantic short password token passed pre-parse"
fi
rm -f "$extractor_tmp"
trap - EXIT
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
if 'while iptables -w 2 -D INPUT -m comment --comment' in transit + landing:
    die("iptables comment-only deletion can leave swap jump residue after chain rename")
if 'while ip6tables -w 2 -D INPUT -m comment --comment' in landing:
    die("ip6tables comment-only deletion can leave swap jump residue after chain rename")
if 'stale_swap_line=$(iptables -w 2 -L INPUT --line-numbers -n' not in transit:
    die("transit health check does not clean stale firewall swap jump by line number")
if 'stale_swap_line=$($tool -w 2 -L INPUT --line-numbers -n' not in landing:
    die("landing health check does not clean stale firewall swap jump by line number")
if '_transit_rules+="iptables -w 2 -A __FW_CHAIN__-NEW -s ${_tip}/32 -p tcp --dport ${LANDING_PORT}' not in landing:
    die("landing persisted firewall transit rules must render the real landing port before template insertion")
if '_transit_rules+="iptables -w 2 -A __FW_CHAIN__-NEW -s ${_tip}/32 -p tcp --dport __LANDING_PORT__' in landing:
    die("landing persisted firewall transit rules still contain a late __LANDING_PORT__ placeholder")
if 'repair_transit_maps_from_meta' not in transit:
    die("transit health check must repair missing/drifted .map files from .meta during long-running cron checks")
if '.transit-map-repair.' not in transit:
    die("transit .map health repair must use temporary files/snapshots for rollback")
if 'disable_packaged_nginx_default_site' not in transit:
    die("transit install must disable Debian nginx default site to avoid extra port 80 listeners")
if 'NGINX_DEFAULT_SITE_DISABLED_FLAG' not in transit:
    die("transit default-site disable must leave a marker for uninstall restore")
if '{"alpn": "h2", "dest": PORT_VLESS_GRPC, "xver": 0}' not in landing:
    die("landing VLESS-gRPC fallback must keep generic h2 routing for Xray gRPC clients")
if 'path": f"/{PFX}-vg/Tun"' in landing or 'path": f"/{PFX}-vg/TunMulti"' in landing:
    die("landing VLESS-gRPC fallback must not use exact Tun/TunMulti path matching")

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
if '_existing_node=$(find "$CONF_DIR" -name "*.meta" -type f -exec grep -l "^DOMAIN=${dom}$" {} + 2>/dev/null | head -1 || true)' not in transit:
    die("transit import must tolerate no existing-domain match when adding the second landing")

fresh_preflight = between(transit, 'fresh_install(){', 'check_deps', "transit fresh preflight")
if fresh_preflight.find('extract_import_token_json_no_deps "$LANDING_TOKEN" >/dev/null') < 0:
    die("fresh_install does not pre-parse LANDING_TOKEN")

headless_ip = between(landing, 'DNS_PLACEHOLDER_IP="${LANDING_AUTO_DNS_PLACEHOLDER_IP', 'info "检测到无头静默安装模式', "landing headless IP")
if 'validate_dns_placeholder_ipv4 "$DNS_PLACEHOLDER_IP"' not in headless_ip:
    die("headless DNS placeholder IP is not validated")
if 'validate_ipv4 "$LANDING_AUTO_PUBLIC_IP"' not in headless_ip:
    die("headless LANDING_AUTO_PUBLIC_IP is not validated as real public IPv4")
if 'PUB_IP="${LANDING_AUTO_PUBLIC_IP}"' in headless_ip:
    die("headless preflight should not copy LANDING_AUTO_PUBLIC_IP into ambient PUB_IP")

purge_nginx = between(landing, 'if (( _nginx_installed_by_script )); then', 'rm -rf "$MANAGER_BASE"', "purge_all nginx cleanup")
if purge_nginx.find('systemctl reload nginx') > purge_nginx.find('restore_packaged_nginx_default_site'):
    die("purge_all restores Debian default site before nginx reload")

rollback_nginx = between(landing, 'elif systemctl is-active --quiet nginx 2>/dev/null; then', 'systemctl reset-failed nginx', "fresh rollback nginx cleanup")
if 'systemctl restart nginx' in rollback_nginx:
    die("fresh rollback must not restart user-owned nginx after default-site restore")
if rollback_nginx.find('systemctl reload nginx') > rollback_nginx.find('restore_packaged_nginx_default_site'):
    die("fresh rollback restores Debian default site before nginx reload")

fresh_landing_precheck = between(landing, '[[ "$CONFIRM" =~ ^[Yy]$ ]]', 'check_deps', "landing fresh dependency precheck")
if fresh_landing_precheck.find('__LANDING_FRESH_INSTALL_TRAP_ACTIVE=1') < 0:
    die("landing fresh install does not activate rollback before check_deps")
if fresh_landing_precheck.find("trap '_fresh_install_rollback' ERR") < 0:
    die("landing fresh install does not trap dependency-stage ERR before check_deps")
if fresh_landing_precheck.find('if [[ -f "$INSTALLED_FLAG" ]]') > fresh_landing_precheck.find('__LANDING_FRESH_INSTALL_TRAP_ACTIVE=1'):
    die("landing fresh install activates destructive rollback before duplicate-install guard")

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

if 'landing_firewall_has_transit_rule "$NEW_TRANSIT"' not in landing:
    die("add_node does not verify live+persisted firewall before skipping rebuild")
if '删除已回滚，但服务仍无法恢复' not in landing:
    die("delete_node does not hard-fail when rollback cannot restore service")
if '运行链白名单' not in landing or '恢复脚本白名单' not in landing:
    die("show_status does not validate transit firewall rule port")
if 'ensure_cloudflare_placeholder_a_record "$DOMAIN" "$CF_TOKEN" "$DNS_PLACEHOLDER_IP"' not in landing:
    die("fresh install does not ensure optional DNS placeholder before certificate issue")
if 'DNS_PLACEHOLDER_RECORD_ID=${dns_record_id}' not in landing:
    die("node state does not persist DNS placeholder record id")
if '[[ -z "$record_id" ]] && return 0' not in landing:
    die("DNS placeholder delete is not guarded by record id")
if 'rm -f "$LANDING_BIN" "$CERT_RELOAD_SCRIPT" "$LOGROTATE_FILE"' not in landing:
    die("purge_all does not remove logrotate file")
if 'validate_ipv4 "$pub_ip" || die' not in landing:
    die("print_pairing_info does not enforce real public IPv4 token IP")
if 'ip.is_private' not in transit:
    die("transit token pre-parse does not reject private IP addresses")
if 'type=tcp&alpn=http/1.1' not in transit or 'type=tcp&alpn=http/1.1' not in landing:
    die("Trojan-TCP links must use explicit alpn=http/1.1")
if 'type=tcp&alpn=#{urllib.parse.quote' in transit or 'type=tcp&alpn="\\n' in landing:
    die("Trojan-TCP links must not emit empty alpn")
if 'type=tcp&alpn=http/1.0' in transit or 'type=tcp&alpn=http/1.0' in landing:
    die("Trojan-TCP links must not use alpn=http/1.0; local Xray test fails with current fallback split")
if '&type=grpc&serviceName={pfx}-vg&authority={domain}&alpn=h2&mode=multi' not in transit:
    die("transit VLESS-gRPC link must include authority=domain for HTTP/2 client compatibility")
if 'f"&type=grpc&serviceName={pfx}-vg&authority={domain}&alpn=h2&mode=multi"' not in landing:
    die("landing VLESS-gRPC link must include authority=domain for HTTP/2 client compatibility")
if '-m comment --comment "xray-landing-transit" -j ACCEPT 2>/dev/null' not in landing:
    die("landing --status runtime whitelist check must match the managed comment-bearing rule")
health_path = 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
if health_path not in transit or health_path not in landing:
    die("generated health checks must set PATH with sbin for cron environments")

print(f"OK: static invariants for {tv}")
PY
