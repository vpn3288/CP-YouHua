#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
# install_transit_v6.16.sh — 中转机安装脚本 v6.16
# 架构: CN2 GIA 纯 IPv4 中转机；Nginx stream SNI 盲传；禁止代理核心和 IPv6 业务路径。
# v6.16: 导入 token 预解析拒绝畸形 JSON，避免坏 token 触发安装副作用。
# 历史版本细节请查看 Git 提交记录；脚本头部只保留当前维护所需事实，避免旧协议/旧 IPv6 说明误导。

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
readonly VERSION="v6.16"
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() {
  error "$*"
  if declare -F _fresh_install_rollback >/dev/null; then _fresh_install_rollback 2>/dev/null || true; fi
  if declare -F _import_install_rollback >/dev/null; then _import_install_rollback 2>/dev/null || true; fi
  if declare -F _route_rollback >/dev/null; then _route_rollback 2>/dev/null || true; fi
  exit 1
}
readonly MANAGER_BASE="/etc/transit_manager"
readonly CONF_DIR="${MANAGER_BASE}/conf"
readonly INSTALLED_FLAG="${MANAGER_BASE}/.installed"
readonly NGINX_MAIN_CONF="/etc/nginx/nginx.conf"
readonly NGINX_STREAM_CONF="/etc/nginx/stream-transit.conf"
readonly TRANSIT_FALLBACK_CONF="/etc/nginx/conf.d/transit-fallback.conf"
readonly SNIPPETS_DIR="/etc/nginx/stream-snippets"
readonly STREAM_INCLUDE_MARKER="transit-manager-stream-include"
readonly LISTEN_PORT=443
readonly FW_CHAIN="TRANSIT-MANAGER"
readonly LOG_DIR="/var/log/transit-manager"
readonly LOGROTATE_FILE="/etc/logrotate.d/transit-manager"
readonly UPDATE_WARN_FILE="/var/run/transit-manager.update.warn"

_delete_input_refs_to_chain(){
  local _chain="$1" _lines _n
  mapfile -t _lines < <(iptables -w 2 -L INPUT --line-numbers -n 2>/dev/null | awk -v c="$_chain" '$2==c {print $1}' | sort -rn)
  for _n in "${_lines[@]}"; do
    iptables -w 2 -D INPUT "$_n" 2>/dev/null || true
  done
}

# [F1] Startup stale snapshot sweep — SIGKILL leaves .snap-recover files that EXIT trap cannot clean
find /etc/transit_manager /etc/nginx /etc/systemd/system \
  -maxdepth 5 -name '.snap-recover.*' -mtime +1 -delete 2>/dev/null || true

# BUG-02: 中断时只清理 atomic_write 残留；事务快照由各事务自行提交/回滚。
# 不在 EXIT 广扫 .snap-recover.*，避免只读状态检查误删其他实例的活跃回滚快照。
# [v2.13 GPT-🔴 + Grok-🔴] Cleanup restricted exclusively to script-owned directories.
# Broad /tmp scans risk touching unrelated user files; all scratch files are now under
# ${MANAGER_BASE}/tmp so a targeted find there is sufficient and safe.
_global_cleanup(){
  find /etc/transit_manager /etc/nginx \
    /etc/systemd/system /etc/logrotate.d \
    -maxdepth 5 \
    -name '.transit-mgr.*' \
    -type f -delete 2>/dev/null || true
  # Script-owned tmp — the only scratch space used since v2.13
  find "${MANAGER_BASE}/tmp" \
    -maxdepth 1 -type f \
    \( -name '.transit-mgr.*' -o -name '.nginx-conf-snap.*' \) \
    -delete 2>/dev/null || true
}
_emit_update_warning(){
  wait "${UPDATE_CHECK_PID:-}" 2>/dev/null || true
  if [[ -s "$UPDATE_WARN_FILE" ]]; then
    cat "$UPDATE_WARN_FILE" 2>/dev/null || true
  fi
  rm -f "$UPDATE_WARN_FILE" 2>/dev/null || true
}
trap '_emit_update_warning; _global_cleanup' EXIT
trap 'echo -e "\n${RED}[中断] 安装已中断。如需清理残留，请执行: bash $0 --uninstall${NC}"; exit 1' INT TERM

trim(){
  local s=${1-}
  s="${s#${s%%[!' '	\
]*}}"
  s="${s%${s##*[!' '	\
]}}"
  printf '%s' "$s"
}

# [v2.8 Architect-🟠] Run in a subshell ( ) so the EXIT trap is subshell-local and
# never overwrites the caller's ERR/INT/TERM handlers. Previously the RETURN/ERR trap
# inside atomic_write silently degraded outer rollback handlers to "temp-file cleanup only."
atomic_write()(
  set -euo pipefail
  local target="$1" mode="$2" owner_group="${3:-root:root}" dir tmp
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.transit-mgr.XXXXXX" 2>/dev/null)" \
    || { echo "atomic_write: mktemp failed for $dir" >&2; exit 1; }
  trap 'rm -f "$tmp" 2>/dev/null || true' EXIT
  cat >"$tmp" \
    || { echo "atomic_write: cat to $tmp failed" >&2; exit 1; }
  sync -d "$tmp" \
    || { echo "atomic_write: sync $tmp failed" >&2; rm -f "$tmp"; exit 1; }
  chmod "$mode" "$tmp" \
    || { echo "atomic_write: chmod failed for $tmp" >&2; exit 1; }
  chown "$owner_group" "$tmp" 2>/dev/null \
    || { echo "atomic_write: chown failed for $tmp" >&2; exit 1; }
  mv -f "$tmp" "$target" \
    || { echo "atomic_write: mv $tmp -> $target failed" >&2; exit 1; }
)

ensure_fallback_blackhole(){
  mkdir -p "$(dirname "$TRANSIT_FALLBACK_CONF")" || return 1
  atomic_write "$TRANSIT_FALLBACK_CONF" 644 root:root <<'FALLBACK_EOF'
# transit-manager: local SNI blackhole
server {
    listen 127.0.0.1:9999 ssl;
    ssl_reject_handshake on;
}
FALLBACK_EOF
  return 0
}

_fallback_blackhole_ok(){
  [[ -f "$TRANSIT_FALLBACK_CONF" ]] || return 1
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn 2>/dev/null | awk '$4=="127.0.0.1:9999"{ok=1} END{exit !ok}' && return 0
  fi
  timeout 2 bash -c '</dev/tcp/127.0.0.1/9999' >/dev/null 2>&1
}

_nginx_log_user(){ id -u www-data >/dev/null 2>&1 && printf 'www-data' || { id -u nginx >/dev/null 2>&1 && printf 'nginx' || printf 'root'; }; }
_nginx_log_group(){ getent group adm >/dev/null 2>&1 && printf 'adm' || printf 'root'; }

# v2.32: 全局写操作互斥锁，防止两个终端并发修改同一状态
# [v2.13 GPT-🔴] Lock file moved from /tmp to script-owned ${MANAGER_BASE}/tmp so interrupted
# runs cannot leave phantom locks visible to unrelated processes and the directory is
# cleaned up on --uninstall rather than left in the global temporary namespace.
# mkdir -p is called inside _acquire_lock so the path always exists before flock.
readonly TRANSIT_LOCK_FILE="${MANAGER_BASE}/tmp/transit-manager.lock"
# [v5.68] 修复 v5.67 的 stderr 恢复逻辑错误
# 问题：exec 2>&201 会永久改变 stderr 指向，第3次调用时 stderr 指向已关闭的 fd 201
# 修复：移除 stderr 保存/恢复逻辑，exec 200> 本身不应该影响 stderr
_acquire_lock(){
  mkdir -p "${MANAGER_BASE}/tmp"
  exec 200>"$TRANSIT_LOCK_FILE"
  flock -w 10 200 || die "配置正在被其他进程修改，请稍后重试（等待超时 10s）"
}
_release_lock(){ 
  flock -u 200 2>/dev/null || true
  # [v5.69 FIX] NEVER use 2>/dev/null with exec N>&- — it permanently redirects stderr to /dev/null
  # Bash bug: "exec 200>&- 2>/dev/null" leaks the stderr redirect, breaking all subsequent >&2 output
  exec 200>&- || true
}

# SSH 端口探测：防止防火墙重建时误封当前 SSH。
detect_ssh_port(){
  local p=""
  if command -v sshd >/dev/null 2>&1; then
    p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  fi
  if [[ -z "${p:-}" ]]; then
    p="$(ss -H -tlnp 2>/dev/null | awk '
      $1=="LISTEN" && /sshd/ {
        addr=$4
        sub(/^.*:/,"",addr)
        gsub(/^\[/,"",addr)
        gsub(/\]$/,"",addr)
        if (addr ~ /^[0-9]+$/) { print addr; exit }
      }' | sort -n | head -1 || true)"
  fi
  if [[ -z "${p:-}" ]]; then
    p="$(grep -RhsE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null | awk '{print $2}' | sort -n | head -1 || true)"
  fi
  # 🔴 Grok: 兜底 22 会写错防火墙白名单，探测失败必须中止
  if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
    # 允许环境变量覆盖，方便自动化场景
    if [[ "${detect_ssh_port_override:-}" =~ ^[0-9]+$ ]] && (( detect_ssh_port_override >= 1 && detect_ssh_port_override <= 65535 )); then
      p="$detect_ssh_port_override"
    else
      echo -e "${RED}[FATAL]${NC} 无法探测 SSH 端口（sshd -T、ss、sshd_config 均失败）。" \
      "请以 detect_ssh_port_override=<端口> 环境变量指定后重试。" >&2
      exit 1
    fi
  fi
  # [T-7] Check for SSH on port 443 conflict
  if [[ "$p" == "443" ]]; then
    die "SSH is on port 443, which conflicts with transit listener. Please change SSH port first."
  fi
    printf '%s\n' "$p"
}

validate_domain(){
  local d
  d="$(trim "$1")"
  # RFC1035 长度守卫 + 必须含点
  if ! (( ${#d} >= 4 && ${#d} <= 253 )); then
    error "域名长度非法 (${#d}): $d"
    return 1
  fi
  if [[ "$d" != *"."* ]]; then
    error "域名必须包含至少一个点: $d"
    return 1
  fi
  if ! printf '%s' "$d" | python3 -c "import sys,re; d=sys.stdin.read().strip(); pat=re.compile(r'^(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)(?:\.(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?))*\.[a-zA-Z0-9]{2,}$'); sys.exit(0 if pat.match(d) else 1)" >/dev/null 2>&1; then
    error "域名格式非法: $d"
    return 1
  fi
  return 0
}

validate_ipv4(){
  local ip="$1"
  if ! printf '%s' "$ip" | python3 -c "import ipaddress, sys
ip = sys.stdin.read().strip()
try:
    a = ipaddress.IPv4Address(ip)
    if a.is_loopback or a.is_link_local or a.is_multicast or a.is_reserved or a.is_unspecified:
        sys.exit(1)
except:
    sys.exit(1)
" >/dev/null 2>&1; then
    error "IPv4 格式非法: $ip"
    return 1
  fi
  return 0
}

validate_ip(){
  local ip="$1"
  if [[ "$ip" =~ : ]]; then
    error "拓扑冲突：中转机无 IPv6 路由时（CN2GIA），严禁使用 IPv6 落地机地址: $ip"
    return 1
  fi
  validate_ipv4 "$ip"
}

_assert_no_proxy_core_transit(){
  if command -v xray &>/dev/null || [[ -f /usr/local/bin/xray ]] \
     || command -v v2ray &>/dev/null || [[ -f /usr/local/bin/v2ray ]] \
     || command -v trojan &>/dev/null || [[ -f /usr/local/bin/trojan ]] \
     || command -v sing-box &>/dev/null || [[ -f /usr/local/bin/sing-box ]]; then
    die "检测到代理核心已安装，中转机不能运行代理服务，请使用纯净系统"
  fi
  if command -v mack-a &>/dev/null || [[ -f /etc/v2ray-agent/install.sh ]]; then
    die "检测到 mack-a 已安装，请先卸载 mack-a 后再安装本脚本"
  fi
  if [[ -f /etc/nginx/nginx.conf ]] && grep -q "v2ray-agent" /etc/nginx/nginx.conf 2>/dev/null; then
    die "检测到mack-a的nginx配置，请先卸载mack-a"
  fi
}

validate_port(){
  local p="$1"
  if ! [[ "$p" =~ ^[1-9][0-9]*$ ]]; then
    error "端口格式非法（不允许前导零）: $p"
    return 1
  fi
  if ! (( 10#$p >= 1 && 10#$p <= 65535 )); then
    error "端口需在 1-65535: $p"
    return 1
  fi
  return 0
}

domain_to_safe()  {
  local raw
  local hash
  raw="$(printf '%s' "$1" | tr '.' '_' | tr -cd 'a-zA-Z0-9_-')"
  hash="$(printf '%s' "$1" | sha256sum | awk '{print substr($1,1,64)}')"
  printf '%s_%s' "${raw:0:60}" "$hash"
}
nginx_domain_str(){ printf '%s' "$1" | tr -cd 'a-zA-Z0-9._-'; }
nginx_ip_str()    { printf '%s' "$1" | tr -cd 'a-zA-Z0-9.'; }
# [F2] Compatibility reader: accepts both old IP= and new TRANSIT_IP= field names in .meta files.
# Old files written before v2.3 used IP=; new files use TRANSIT_IP=.
read_meta_ip()    { awk -F= '/^(TRANSIT_IP|IP)=/{print $2; exit}' "$1"; }
_map_matches_meta_projection(){
  local _map="$1" _domain="$2" _ip="$3" _port="$4" _key _backend
  [[ -f "$_map" ]] || return 1
  _key=$(nginx_domain_str "$_domain")
  _backend="$(nginx_ip_str "$_ip"):${_port}"
  [[ -n "$_key" && -n "$_backend" ]] || return 1
  awk -v k="$_key" -v b="$_backend" '
    /^[[:space:]]*($|#)/ { next }
    {
      field_count = NF
      gsub(/;$/, "", $2)
      if ($1 == k && $2 == b && field_count == 2) {
        ok = 1
      } else {
        bad = 1
      }
      count++
    }
    END { exit !(count == 1 && ok == 1 && bad == 0) }
  ' "$_map" 2>/dev/null
}
_meta_drift_detect(){
  [[ -d "$SNIPPETS_DIR" && -d "$CONF_DIR" ]] || return 1
  local _mf _mdom _mip _mport _msafe _map _safe _bad=0
  while IFS= read -r _mf; do
    [[ -f "$_mf" ]] || continue
    _mdom=$(grep '^DOMAIN=' "$_mf" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}' || true)
    _mip=$(read_meta_ip "$_mf" 2>/dev/null || true)
    _mport=$(grep '^PORT=' "$_mf" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}' || true)
    [[ -n "$_mdom" && -n "$_mip" && -n "$_mport" ]] || { _bad=1; break; }
    validate_domain "$_mdom" 2>/dev/null || { _bad=1; break; }
    validate_ipv4 "$_mip" 2>/dev/null || { _bad=1; break; }
    validate_port "$_mport" 2>/dev/null || { _bad=1; break; }
    _msafe=$(domain_to_safe "$_mdom")
    _map="${SNIPPETS_DIR}/landing_${_msafe}.map"
    _map_matches_meta_projection "$_map" "$_mdom" "$_mip" "$_mport" || { _bad=1; break; }
  done < <(find "$CONF_DIR" -maxdepth 1 -type f -name '*.meta' 2>/dev/null | sort)
  while IFS= read -r _map; do
    [[ -f "$_map" ]] || continue
    _safe=$(basename "$_map")
    _safe="${_safe#landing_}"
    _safe="${_safe%.map}"
    [[ -f "${CONF_DIR}/${_safe}.meta" ]] || { _bad=1; break; }
  done < <(find "$SNIPPETS_DIR" -maxdepth 1 -type f -name 'landing_*.map' ! -name '*dummy*' 2>/dev/null | sort)
  return $_bad
}

_repair_maps_from_meta(){
  [[ -d "$CONF_DIR" ]] || return 1
  mkdir -p "$SNIPPETS_DIR" || { warn "创建 snippets 目录失败: $SNIPPETS_DIR"; return 1; }
  chmod 700 "$SNIPPETS_DIR" 2>/dev/null || true
  local _mf _mdom _mip _mport _msafe _map _tmp _snap _had_map _changed=0 _failed=0
  local -a _changed_maps=() _changed_snaps=() _changed_had_maps=()
  while IFS= read -r _mf; do
    [[ -f "$_mf" ]] || continue
    _mdom=$(grep '^DOMAIN=' "$_mf" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}' || true)
    _mip=$(read_meta_ip "$_mf" 2>/dev/null || true)
    _mport=$(grep '^PORT=' "$_mf" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}' || true)
    [[ -n "$_mdom" && -n "$_mip" && -n "$_mport" ]] || { warn "跳过损坏 .meta，字段不完整: $_mf"; _failed=1; continue; }
    validate_domain "$_mdom" 2>/dev/null || { warn "跳过损坏 .meta，域名非法: $_mf"; _failed=1; continue; }
    validate_ipv4 "$_mip" 2>/dev/null || { warn "跳过损坏 .meta，IPv4 非法: $_mf"; _failed=1; continue; }
    validate_port "$_mport" 2>/dev/null || { warn "跳过损坏 .meta，端口非法: $_mf"; _failed=1; continue; }
    _msafe=$(domain_to_safe "$_mdom")
    _map="${SNIPPETS_DIR}/landing_${_msafe}.map"
    _map_matches_meta_projection "$_map" "$_mdom" "$_mip" "$_mport" && continue
    warn "根据 .meta 修复 .map: ${_mdom} -> ${_mip}:${_mport}"
    _snap=""
    _had_map=0
    if [[ -f "$_map" ]]; then
      _had_map=1
      _snap=$(mktemp "${SNIPPETS_DIR}/.snap-recover.XXXXXX") || { warn "mktemp 修复快照失败: $_map"; _failed=1; continue; }
      cp -f "$_map" "$_snap" || { rm -f "$_snap" 2>/dev/null || true; warn "复制修复快照失败: $_map"; _failed=1; continue; }
    fi
    _tmp=$(mktemp "${SNIPPETS_DIR}/.snap-recover.XXXXXX") || { warn "mktemp 修复 .map 失败: $_map"; _failed=1; continue; }
    printf '    %s    %s:%s;\n' "$(nginx_domain_str "$_mdom")" "$(nginx_ip_str "$_mip")" "$_mport" > "$_tmp" \
      || { rm -f "$_tmp" "$_snap" 2>/dev/null || true; warn "写入临时 .map 失败: $_map"; _failed=1; continue; }
    chmod 600 "$_tmp" 2>/dev/null || true
    if mv -f "$_tmp" "$_map"; then
      chmod 600 "$_map" 2>/dev/null || true
      _changed_maps+=("$_map")
      _changed_snaps+=("$_snap")
      _changed_had_maps+=("$_had_map")
      _changed=1
    else
      rm -f "$_tmp" "$_snap" 2>/dev/null || true
      warn "提交修复 .map 失败: $_map"
      _failed=1
    fi
  done < <(find "$CONF_DIR" -maxdepth 1 -type f -name '*.meta' 2>/dev/null | sort)
  if (( _changed )); then
    if ! nginx_reload >/dev/null 2>&1; then
      local _i
      for ((_i=${#_changed_maps[@]}-1; _i>=0; _i--)); do
        if [[ "${_changed_had_maps[$_i]}" == "1" && -n "${_changed_snaps[$_i]}" && -f "${_changed_snaps[$_i]}" ]]; then
          mv -f "${_changed_snaps[$_i]}" "${_changed_maps[$_i]}" 2>/dev/null || true
        else
          rm -f "${_changed_maps[$_i]}" 2>/dev/null || true
        fi
      done
      rm -f "${_changed_snaps[@]}" 2>/dev/null || true
      if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null \
          || warn ".map 修复回滚后 Nginx 旧运行态 reload/restart 失败，请手动检查"
      else
        warn ".map 修复回滚后 Nginx 配置仍无法通过校验，请手动检查"
      fi
      warn ".map 已从 .meta 修复但 Nginx reload 失败，本次修复已回滚"
      return 1
    fi
    rm -f "${_changed_snaps[@]}" 2>/dev/null || true
  fi
  (( _failed == 0 && _changed == 1 ))
}

_stream_conf_valid(){
  [[ -f "$NGINX_STREAM_CONF" ]] || return 1
  grep -q 'ssl_preread[[:space:]]\+on' "$NGINX_STREAM_CONF" 2>/dev/null || return 1
  grep -q "listen[[:space:]]\+${LISTEN_PORT}[[:space:]]" "$NGINX_STREAM_CONF" 2>/dev/null || return 1
  grep -q 'preread_timeout[[:space:]]\+30s' "$NGINX_STREAM_CONF" 2>/dev/null || return 1
  grep -q 'proxy_connect_timeout[[:space:]]\+30s' "$NGINX_STREAM_CONF" 2>/dev/null || return 1
  grep -q 'proxy_timeout[[:space:]]\+600s' "$NGINX_STREAM_CONF" 2>/dev/null || return 1
  grep -q 'include /etc/nginx/stream-snippets/landing_\*.map' "$NGINX_STREAM_CONF" 2>/dev/null || return 1
  grep -q 'proxy_pass[[:space:]]\+\$backend_upstream' "$NGINX_STREAM_CONF" 2>/dev/null || return 1
  grep -q 'upstream fallback_blackhole' "$NGINX_STREAM_CONF" 2>/dev/null || return 1
  grep -q 'server 127\.0\.0\.1:9999' "$NGINX_STREAM_CONF" 2>/dev/null || return 1
  grep -q 'default[[:space:]]\+fallback_blackhole' "$NGINX_STREAM_CONF" 2>/dev/null || return 1
}
_main_stream_include_valid(){
  [[ -f "$NGINX_MAIN_CONF" ]] || return 1
  grep -q "$STREAM_INCLUDE_MARKER" "$NGINX_MAIN_CONF" 2>/dev/null || return 1
  grep -qF "include ${NGINX_STREAM_CONF};" "$NGINX_MAIN_CONF" 2>/dev/null || return 1
}
_route_key_conflict(){
  local _dom="$1" _exclude="${2:-}" _needle _paths _conflict=""
  _needle=$(nginx_domain_str "$_dom")
  [[ -d "$SNIPPETS_DIR" ]] || return 0
  _paths=$(find "$SNIPPETS_DIR" -maxdepth 1 -type f -name 'landing_*.map' 2>/dev/null     | while IFS= read -r _map; do
        awk -v d="$_needle" '$1 == d {print FILENAME; exit}' "$_map" 2>/dev/null || true
      done)
  if [[ -n "${_exclude:-}" && -n "${_paths:-}" ]]; then
    _paths=$(printf '%s
' "$_paths" | grep -vFx -- "$_exclude" 2>/dev/null || true)
  fi
  _conflict=$(printf '%s
' "${_paths:-}" | sed '/^$/d' | head -1)
  printf '%s' "$_conflict"
}

# ARCH-2: 中转机公网 IP — 两种调用模式
# get_public_ip [--strict]：strict 模式下获取失败直接 die（用于 Token/订阅生成）
# get_public_ip           ：宽松模式返回占位符（仅用于只读展示）
get_public_ip(){
  # v2.22: Bug2 - 环境变量检查移到函数开头，优先使用
  # v2.24: P1 - env var需要验证
  [[ -n "${TRANSIT_PUBLIC_IP:-}" ]] && { validate_ip "$TRANSIT_PUBLIC_IP"; printf "%s" "$TRANSIT_PUBLIC_IP"; return 0; }
  local _strict=0
  [[ "${1:-}" == "--strict" ]] && _strict=1
  local _ip=""
  local _src
  # [R-4] Restore default IFS (space/tab/newline) before iterating space-separated list
  local IFS=$' \t\n'
  for _src in     "https://api.ipify.org"     "https://ifconfig.me"     "https://checkip.amazonaws.com"     "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip"     "http://169.254.169.254/latest/meta-data/public-ipv4"     "https://ipecho.net/plain"; do
    if [[ "$_src" == *"metadata.google.internal"* ]]; then
      _ip=$(curl -4 -fsSL --connect-timeout 2 --max-time 3 --retry 2 -H "Metadata-Flavor: Google" "$_src" 2>/dev/null | tr -d '[:space:]') || true
    else
      _ip=$(curl -4 -fsSL --connect-timeout 2 --max-time 3 --retry 2 "$_src" 2>/dev/null | tr -d '[:space:]') || true
    fi
    [[ -n "$_ip" ]] && break
  done
  if [[ -n "$_ip" ]] && ! validate_ip "$_ip" >/dev/null 2>&1; then
    if (( _strict )); then
      die "公网 IPv4 探测返回非法值: $_ip"
    fi
    warn "公网 IPv4 探测返回非法值，展示将使用占位符 <TRANSIT_IP>"
    _ip=""
  fi
  # [Doc3-3] strict 模式：IP 获取失败 → 硬退出，占位符绝不进入 Token/订阅生成链路
  # [v5.49-CRITICAL-1] 删除IPv6探测 - 中转机必须纯IPv4，不能有任何IPv6降级逻辑
  if [[ -z "$_ip" ]]; then
    if (( _strict )); then
      die "无法获取中转机公网 IPv4，节点订阅无法生成。请检查网络或手动指定: TRANSIT_PUBLIC_IP=x.x.x.x bash $0 --import <token>"
    else
      warn "无法获取中转机公网 IPv4，展示将使用占位符 <TRANSIT_IP>"
      _ip="<TRANSIT_IP>"
    fi
  fi
  printf '%s' "$_ip"
}

show_help(){
  cat <<HELP
用法: bash install_transit.sh [选项]

  （无参数）        交互式安装或管理菜单
  --uninstall       清除本脚本所有内容（不影响 mack-a）
  --import <token>  从落地机 Base64 token 自动导入路由规则
  --status          显示当前状态
  --help            显示此帮助
HELP
}

check_deps(){
  export DEBIAN_FRONTEND=noninteractive
  # 二进制名与包名分离：iproute2→ip, psmisc→fuser
  local ip_pkg="iproute2"
  if command -v yum &>/dev/null || command -v dnf &>/dev/null; then
    ip_pkg="iproute"
  fi
  local _bin_pkg=(
    curl:curl wget:wget iptables:iptables python3:python3
    ip:${ip_pkg} nginx:nginx fuser:psmisc chronyc:chrony
  )
  local missing_pkgs=()
  for bp in "${_bin_pkg[@]}"; do
    local bin="${bp%%:*}" pkg="${bp##*:}"
    command -v "$bin" &>/dev/null || missing_pkgs+=("$pkg")
  done
  local missing=("${missing_pkgs[@]}")
  if (( ${#missing[@]} > 0 )) && command -v apt-get &>/dev/null; then
    local _lw=0
    if command -v fuser &>/dev/null; then
      while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        sleep 2; ((_lw+=2))
        if ((_lw>60)); then die "apt 锁等待超时（另一个 apt 进程正在运行），请稍后重试"; fi
      done
    else
      sleep 5
    fi
    apt-get update -qq 2>/dev/null || true
    for d in "${missing[@]}"; do
      apt-get install -y "$d" 2>/dev/null || die "安装 $d 失败"
    done
  elif (( ${#missing[@]} > 0 )); then
    for d in "${missing[@]}"; do
      yum install -y "$d" 2>/dev/null || dnf install -y "$d" 2>/dev/null || die "无法安装 $d"
    done
  fi
  # 验证关键二进制均可用
  for bp in "${_bin_pkg[@]}"; do
    local bin="${bp%%:*}"
    command -v "$bin" &>/dev/null || die "依赖 ${bin} 安装后仍无法找到"
  done
  # [BOTH-CRITICAL-FIX] 强制启用时间同步并验证状态,防止时钟漂移导致VLESS断流
  if command -v chronyc &>/dev/null; then
    local _chrony_unit="chrony"
    systemctl list-unit-files chronyd.service 2>/dev/null | grep -q '^chronyd\.service' && _chrony_unit="chronyd"
    systemctl list-unit-files chrony.service 2>/dev/null | grep -q '^chrony\.service' && _chrony_unit="chrony"
    systemctl enable --now "$_chrony_unit" 2>/dev/null || die "${_chrony_unit}启动失败"
    chronyc makestep 2>/dev/null || warn "时间强制同步失败"
    sleep 3
    # 验证时间同步状态
    local _offset=$(chronyc tracking 2>/dev/null | awk '/Last offset/{print $4}' | tr -d '+' | tr -d 's')
    if [[ -n "$_offset" ]]; then
      # 使用awk进行浮点数比较（避免依赖bc）
      local _offset_abs=$(echo "$_offset" | tr -d '-')
      if awk -v offset="$_offset_abs" 'BEGIN{exit !(offset < 2)}'; then
        success "时间同步正常（偏移: ${_offset}s）"
      else
        die "时钟偏移过大（${_offset}s），VLESS将断流，请先手动同步时间"
      fi
    else
      # [H3] 时间同步验证强化 - 空值直接die
      die "chrony无法获取时钟偏移量，请等待30秒后重试"
    fi
  fi
}

optimize_kernel_network(){
  local bbr_conf="/etc/sysctl.d/99-transit-bbr.conf"
  [[ -f "$bbr_conf" ]] && grep -q 'tcp_timestamps' "$bbr_conf" 2>/dev/null && return 0

  info "优化内核并发参数（拥塞控制权归 BBRPlus）..."
  # v2.48 Gemini: tcp_max_tw_buckets 动态计算（每桶256B；内存MB×100，保底10000，上限250000）
  local _ram_mb; _ram_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $2}'); _ram_mb=${_ram_mb:-1024}
  local _tw_max=$(( _ram_mb * 100 ))
  (( _tw_max < 10000 ))  && _tw_max=10000
  (( _tw_max > 250000 )) && _tw_max=250000
  # [v2.7 Gemini-Doc1-🟠] Dynamic fs.file-max / fs.nr_open: fixed 10M on a 512MB VPS still
  # consumes PAM/kernel overhead; scale to RAM×800 (floor 524288, cap 10485760) so SSH subshells
  # and PAM sessions are not FD-starved when nginx workers each hold ~1M FD slots.
  local _ram_mb_fd; _ram_mb_fd=$(free -m 2>/dev/null | awk '/Mem:/{print $2}'); _ram_mb_fd=${_ram_mb_fd:-1024}
  local _fd_max=$(( _ram_mb_fd * 800 ))
  (( _fd_max < 524288 ))  && _fd_max=524288
  (( _fd_max > 10485760 )) && _fd_max=10485760
  cat > "$bbr_conf" <<BBRCF
net.netfilter.nf_conntrack_max=1048576
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=${_tw_max}
net.ipv4.ip_local_port_range=1024 65535
net.core.somaxconn=65535
# [v2.7] fs.nr_open / fs.file-max dynamic (RAM MB × 800, floor 524288, cap 10485760)
fs.nr_open=${_fd_max}
fs.file-max=${_fd_max}
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_mtu_probing=1
BBRCF
  cat >> "$bbr_conf" <<'BBRCF2'
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_fastopen=0
BBRCF2
  # [R7 Fix] Defense-in-depth: protect against hardlink/symlink exploitation
  cat >> "$bbr_conf" <<'BBRCF3'
fs.protected_hardlinks=1
fs.protected_symlinks=1
BBRCF3
  # v2.42 Grok: conntrack hashsize 按内存动态计算（每条目~300B，用1/8内存）
  local _ct_mem; _ct_mem=$(free -m 2>/dev/null | awk '/Mem:/{print int($2/8*1024*1024/300)}'); _ct_mem=${_ct_mem:-262144}
  [[ "$_ct_mem" =~ ^[0-9]+$ ]] || _ct_mem=262144
  (( _ct_mem < 131072 )) && _ct_mem=131072
  atomic_write "/etc/modprobe.d/nf_conntrack.conf" 644 root:root <<MEOF
options nf_conntrack hashsize=${_ct_mem}
MEOF
  modprobe nf_conntrack 2>/dev/null || true
  echo "$_ct_mem" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
  # nf_conntrack_max 也动态设为 hashsize*4
  local _ct_max=$(( _ct_mem * 4 ))
  sysctl -w net.netfilter.nf_conntrack_max="${_ct_max}" &>/dev/null || true
  sed -i "s/net.netfilter.nf_conntrack_max=.*/net.netfilter.nf_conntrack_max=${_ct_max}/"     /etc/sysctl.d/99-transit-bbr.conf 2>/dev/null || true
  
  # [T-CRITICAL-3] TCP流量随机化 - 使用/dev/urandom确保非交互环境可用
  local _tcp_wmem_base=$(od -An -N2 -tu2 /dev/urandom | awk '{print 4096 + ($1 % 4096)}')  # 4-8KB随机基础窗口
  local _tcp_rmem_base=$(od -An -N2 -tu2 /dev/urandom | awk '{print 4096 + ($1 % 4096)}')
  local _tcp_wmem_max=$(od -An -N4 -tu4 /dev/urandom | awk '{print 16777216 + ($1 % 8388608)}')  # 16-24MB随机最大窗口
  local _tcp_rmem_max=$(od -An -N4 -tu4 /dev/urandom | awk '{print 16777216 + ($1 % 8388608)}')
  
  # [T-CRITICAL-3-FIX] 持久化TCP窗口随机化参数到配置文件
  cat >> "$bbr_conf" <<BBRCF4
net.ipv4.tcp_wmem=${_tcp_wmem_base} 87380 ${_tcp_wmem_max}
net.ipv4.tcp_rmem=${_tcp_rmem_base} 87380 ${_tcp_rmem_max}
BBRCF4
  
  # 同时设置运行态
  sysctl -w net.ipv4.tcp_wmem="${_tcp_wmem_base} 87380 ${_tcp_wmem_max}" &>/dev/null || true
  sysctl -w net.ipv4.tcp_rmem="${_tcp_rmem_base} 87380 ${_tcp_rmem_max}" &>/dev/null || true
  
  sysctl --system &>/dev/null || true
  
  # [T-CRITICAL-1-FIX] 验证tcp_timestamps=1是否真正生效
  local _ts_val=$(sysctl -n net.ipv4.tcp_timestamps 2>/dev/null || echo 0)
  if [[ "$_ts_val" == "1" ]]; then
    success "TCP timestamps已启用（反GFW代理检测）"
  else
    die "tcp_timestamps=1 设置失败（当前值: $_ts_val）"
  fi
  
  # [T-CRITICAL-3] TCP窗口验证逻辑修复 - 使用范围验证而非精确匹配
  local _wmem_actual=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)
  local _rmem_actual=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)
  
  # [BOTH-HIGH-1] 时间同步空值守卫 - 防止sysctl失败时误判通过
  if [[ -z "$_wmem_actual" || -z "$_rmem_actual" ]]; then
    die "TCP窗口参数无法读取（sysctl失败）"
  fi
  
  local _wmem_min=$(echo "$_wmem_actual" | awk '{print $1}')
  local _wmem_max=$(echo "$_wmem_actual" | awk '{print $3}')
  local _rmem_min=$(echo "$_rmem_actual" | awk '{print $1}')
  local _rmem_max=$(echo "$_rmem_actual" | awk '{print $3}')
  
  # 验证范围而非精确匹配（随机值不可能精确相等）
  if [[ "$_wmem_min" -ge 4096 && "$_wmem_min" -le 8192 && "$_wmem_max" -ge 16777216 && "$_wmem_max" -le 25165824 ]]; then
    success "TCP发送窗口随机化已生效（${_wmem_min} 87380 ${_wmem_max}）"
  else
    die "TCP发送窗口随机化失败（期望4-8KB/16-24MB，实际: $_wmem_actual）"
  fi
  
  if [[ "$_rmem_min" -ge 4096 && "$_rmem_min" -le 8192 && "$_rmem_max" -ge 16777216 && "$_rmem_max" -le 25165824 ]]; then
    success "TCP接收窗口随机化已生效（${_rmem_min} 87380 ${_rmem_max}）"
  else
    die "TCP接收窗口随机化失败（期望4-8KB/16-24MB，实际: $_rmem_actual）"
  fi
  
  warn "sysctl 配置已重新加载；若需立即回收运行态内核资源，建议重启主机"
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -qi 'bbr' \
    || warn "BBRPlus 未检测到，请确认已运行 one_click_script 并重启后再检查"
  # [v2.8 GPT-Doc2-🟠] PAM limits must match the dynamic _fd_max value.
  # Hard-coded 1048576 on a 512 MB VPS exceeds the dynamic sysctl value (524288),
  # causing SSH subshells and acme.sh cron to hit a PAM hard limit above the kernel ceiling.
  # Idempotent: strip stale nofile block then re-append current value.
  local _lim_file="/etc/security/limits.conf"
  sed -i '/# xray-transit: raised for high-concurrency/,/^root hard nofile/d' "$_lim_file" 2>/dev/null || true
  sed -i '/# transit-manager: raised nofile limit/,/^root hard nofile/d' "$_lim_file" 2>/dev/null || true
  cat >> "$_lim_file" <<LIMEOF
# transit-manager: raised nofile limit
* soft nofile ${_fd_max}
* hard nofile ${_fd_max}
root soft nofile ${_fd_max}
root hard nofile ${_fd_max}
LIMEOF
  success "内核网络参数已优化（conntrack hashsize=${_ct_mem} / 拥塞控制权归 BBRPlus）"
}

install_nginx(){
  # ENV-1 FIX: nginx -V 含 --with-stream=dynamic 但动态库未装时仍报 "unknown directive stream"
  # 必须强制安装 libnginx-mod-stream，不能仅靠 -V 输出判断
  if command -v nginx &>/dev/null; then
    # 已安装：测试 stream 指令是否真的可用（不只是 -V 标志）
    if echo 'events{} stream{}' | nginx -t -c /dev/stdin 2>/dev/null \
        || (nginx -V 2>&1 | grep -qE 'with-stream[^_]' \
           && dpkg -l libnginx-mod-stream 2>/dev/null | grep -q '^ii' 2>/dev/null); then
      success "Nginx 已安装且 stream 模块可用"
    else
      info "Nginx 已安装但 stream 模块不可用，补充安装 libnginx-mod-stream..."
      if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y libnginx-mod-stream 2>/dev/null \
          || warn "libnginx-mod-stream 安装失败，stream 模块可能不可用"
      elif command -v yum &>/dev/null; then
        yum install -y nginx-mod-stream 2>/dev/null \
          || warn "nginx-mod-stream 安装失败，stream 模块可能不可用"
      elif command -v dnf &>/dev/null; then
        dnf install -y nginx-mod-stream 2>/dev/null \
          || warn "nginx-mod-stream 安装失败，stream 模块可能不可用"
      else
        warn "无法识别包管理器，stream 模块可能不可用"
      fi
    fi
  else
    info "安装 Nginx（含 stream 模块）..."
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get &>/dev/null; then
      apt-get update -qq
      # ENV-1 FIX: 同时安装 nginx-common libnginx-mod-stream nginx，确保动态库就位
      apt-get install -y nginx-common libnginx-mod-stream nginx 2>/dev/null \
        || apt-get install -y nginx \
        || die "Nginx 安装失败（apt-get 返回非零），请检查 apt 源或手动安装 nginx libnginx-mod-stream"
    elif command -v yum &>/dev/null; then
      yum install -y epel-release 2>/dev/null || true
      yum makecache 2>/dev/null || true
      yum install -y nginx nginx-mod-stream 2>/dev/null || yum install -y nginx \
        || die "Nginx 安装失败（yum 返回非零）"
    elif command -v dnf &>/dev/null; then
      dnf install -y nginx nginx-mod-stream 2>/dev/null || dnf install -y nginx \
        || die "Nginx 安装失败（dnf 返回非零）"
    else
      die "不支持的包管理器，请手动安装含 stream 模块的 Nginx"
    fi
    success "Nginx 安装完成"
  fi
  local _stream_test_conf
  mkdir -p "${MANAGER_BASE}/tmp"
  _stream_test_conf=$(mktemp "${MANAGER_BASE}/tmp/nginx-stream-test.XXXXXX") \
    || die "无法创建 Nginx stream 测试配置"
  printf 'include /etc/nginx/modules-enabled/*.conf;\ninclude /usr/share/nginx/modules/*.conf;\nevents{}\nstream{}\n' > "$_stream_test_conf"
  nginx -t -c "$_stream_test_conf" >/dev/null 2>&1 \
    || { rm -f "$_stream_test_conf" 2>/dev/null || true; die "Nginx stream 模块不可用，请安装 libnginx-mod-stream/nginx-mod-stream"; }
  rm -f "$_stream_test_conf" 2>/dev/null || true
  
  # 创建 SNI 黑洞守卫：无效/空 SNI 走本地 TLS reject，避免直接 TCP RST。
  ensure_fallback_blackhole || die "SNI 黑洞配置写入失败"
  success "SNI黑洞守卫已配置（127.0.0.1:9999）"
  
  _tune_nginx_worker_connections
}

_tune_nginx_worker_connections(){
  local mc="$NGINX_MAIN_CONF"
  # [F4] Snapshot before sed mutations so nginx.conf can be restored on nginx -t failure
  # [v2.13 GPT-🟠] nginx.conf snapshot moved from /tmp to script-owned MANAGER_BASE/tmp
  mkdir -p "${MANAGER_BASE}/tmp" || die "mkdir ${MANAGER_BASE}/tmp failed"
  local _mc_bak; _mc_bak=$(mktemp "${MANAGER_BASE}/tmp/.nginx-conf-snap.XXXXXX" 2>/dev/null) \
    || die "mktemp _mc_bak failed (disk full?) — cannot proceed without rollback capability"
  cp -a "$mc" "$_mc_bak" || die "nginx.conf snapshot failed — cannot proceed without rollback capability"
  [[ -n "$_mc_bak" ]] || die "mktemp returned empty path"
  local _mc_dirty=0
  # [v2.9 GPT-A-🟠] Recompute _fd_max here (same RAM×800 formula as optimize_kernel_network)
  # so worker_rlimit_nofile always matches the systemd LimitNOFILE drop-in value on this host.
  local _tune_ram_mb; _tune_ram_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $2}'); _tune_ram_mb=${_tune_ram_mb:-1024}
  local _tune_fd=$(( _tune_ram_mb * 800 ))
  (( _tune_fd < 524288 ))   && _tune_fd=524288
  (( _tune_fd > 10485760 )) && _tune_fd=10485760
  local _wc_ram; _wc_ram=$(free -m 2>/dev/null | awk '/Mem:/{print int($2/2*1000)}'); _wc_ram=${_wc_ram:-100000}
  (( _wc_ram < 10000 )) && _wc_ram=10000
  (( _wc_ram > 200000 )) && _wc_ram=200000
  
  # [T-MEDIUM-3] worker_connections随机偏移扩大 - 70-130%范围
  local _wc_base=$((_wc_ram * (50 + RANDOM % 100) / 100))
  local _prime_offset=$((RANDOM % 97))  # 97是质数，增加随机性
  local _wc_offset=$((_wc_base + _prime_offset))
  local _wc_escaped="${VERSION//./\\.}"  # 转义VERSION中的点号用于正则表达式
  grep -qE "^[[:space:]]*worker_connections[[:space:]]+${_wc_offset}[[:space:]]*;[[:space:]]*# transit-manager-tuning-v${_wc_escaped}$" "$mc" 2>/dev/null || {
    _mc_dirty=1
    if grep -qE '^[[:space:]]*worker_connections' "$mc" 2>/dev/null; then
      sed -i -E "s/^([[:space:]]*worker_connections[[:space:]]+)[0-9]+([[:space:]]*;.*)/\1${_wc_offset}; # transit-manager-tuning-v${_wc_escaped}/" "$mc"
    else
      # [v5.37 CRITICAL-16] Fix: \s is not portable in sed, use [[:space:]] instead
      sed -i "/^events[[:space:]]*{/a\    worker_connections ${_wc_offset}; # transit-manager-tuning-v${_wc_escaped}" "$mc"
    fi
  }
  # Idempotent: strip any stale worker_rlimit_nofile line then re-inject current dynamic value
  grep -qE "^worker_rlimit_nofile[[:space:]]+${_tune_fd}[[:space:]]*;[[:space:]]*# transit-manager-tuning-v${_wc_escaped}$" "$mc" 2>/dev/null || {
    _mc_dirty=1
    if grep -qE '^[[:space:]]*worker_rlimit_nofile' "$mc" 2>/dev/null; then
      sed -i "s/^[[:space:]]*worker_rlimit_nofile.*/worker_rlimit_nofile ${_tune_fd}; # transit-manager-tuning-v${_wc_escaped}/" "$mc"
    else
      # [v5.37 CRITICAL-16] Fix: \s is not portable in sed, use [[:space:]] instead
      sed -i "/^events[[:space:]]*{/i\worker_rlimit_nofile ${_tune_fd}; # transit-manager-tuning-v${_wc_escaped}" "$mc"
      info "worker_rlimit_nofile ${_tune_fd} 已写入 nginx.conf"
    fi
  }
  grep -qE "^worker_shutdown_timeout[[:space:]]+10m[[:space:]]*;[[:space:]]*# transit-manager-tuning-v${_wc_escaped}$" "$mc" 2>/dev/null || {
    _mc_dirty=1
    if grep -qE '^[[:space:]]*worker_shutdown_timeout' "$mc" 2>/dev/null; then
      sed -i "s/^.*worker_shutdown_timeout.*/worker_shutdown_timeout 10m; # transit-manager-tuning-v${_wc_escaped}/" "$mc"
    else
      # [v5.37 CRITICAL-16] Fix: \s is not portable in sed, use [[:space:]] instead
      sed -i "/^events[[:space:]]*{/i\worker_shutdown_timeout 10m; # transit-manager-tuning-v${_wc_escaped}" "$mc"
    fi
  }
  # [F4] Validate and roll back if nginx -t fails
  # [v5.38 CRITICAL-17] Fix: nginx -t must show stderr for proper validation
  if ! nginx -t 2>&1 | tee /tmp/nginx-t-output.log | grep -q "test is successful"; then
    warn "nginx.conf tuning validation failed — restoring snapshot"
    # [F1] Hard-fail restore: both mv and cp -a attempted; if both fail the file is corrupted
    if ! mv -f "$_mc_bak" "$mc" 2>/dev/null; then
      cp -a "$_mc_bak" "$mc" || die "nginx.conf restore FAILED — manual fix required: cp ${_mc_bak} ${mc}"
    fi
    die "nginx.conf 配置验证失败，原始配置已还原; 请检查 ${NGINX_MAIN_CONF}"
  fi
  rm -f "$_mc_bak" 2>/dev/null || true
  local override_dir="/etc/systemd/system/nginx.service.d"
  mkdir -p "$override_dir"
  # [v5.35 CRITICAL-14] systemd ReadWritePaths requires the path to exist BEFORE
  # daemon-reload + reload nginx; otherwise namespace setup fails with ENOENT and
  # nginx reload aborts, splitting runtime/file state. Pre-create LOG_DIR here.
  mkdir -p "$LOG_DIR"
  chown root:adm "$LOG_DIR" 2>/dev/null || true
  chmod 750 "$LOG_DIR" 2>/dev/null || true
  # [v2.8 GPT-Doc2-🟠] LimitNOFILE must equal _fd_max (dynamic); always rewrite so a
  # re-run on different-RAM hardware updates the drop-in to the correct value.
  # [v2.9] Use _tune_fd (same formula, recomputed above) for both worker_rlimit_nofile and
  # the drop-in so the nginx.conf directive and the service cap are always identical.
  local _ov="${override_dir}/transit-manager-override.conf"
  atomic_write "$_ov" 644 root:root <<SVCOV
[Unit]
# [v2.9 Architect-🟠] Widened to 600s/10 — installer restarts nginx after rewriting the
# drop-in; 300s/5 was tight enough to trip on a short maintenance burst.
StartLimitIntervalSec=600
StartLimitBurst=10

[Service]
LimitNOFILE=${_tune_fd}
TasksMax=infinity
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/log/nginx /var/lib/nginx /run /var/run /var/log/transit-manager
ProtectHome=true
PrivateTmp=true
UMask=0027
# Gemini: nginx 自管日志，systemd journal 无需重复收集（防低配 VPS 磁盘撑爆）
StandardOutput=null
StandardError=null
SVCOV
  systemctl daemon-reload \
    || die "systemctl daemon-reload failed — drop-in limits will not apply (nginx may hit FD limit under load)"
  if systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx 2>/dev/null \
      || die "Nginx reload 失败（配置已修改但未生效）— 运行态与文件态分裂，请执行: systemctl restart nginx"
  fi
  success "Nginx worker_connections=${_wc_offset} / worker_rlimit_nofile=${_tune_fd} (dynamic)"
}

write_logrotate(){
  mkdir -p "$LOG_DIR"
  local _log_user _log_group
  _log_user="$(_nginx_log_user)"
  _log_group="$(_nginx_log_group)"
  atomic_write "$LOGROTATE_FILE" 644 root:root <<EOF
${LOG_DIR}/*.log
{
    su ${_log_user} ${_log_group}
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 0640 ${_log_user} ${_log_group}
    sharedscripts
    postrotate
        # [v2.7 Gemini-Doc2-🟠] --kill-who=main: deliver USR1 exclusively to the nginx master
        # process; bare systemctl kill targets the entire cgroup (master + workers) and
        # USR1 to workers produces undefined behaviour / silent FD leaks.
        # [v2.11 Doc10-B-🟠] nginx -s reopen fallback: if master is in reload window, the
        # USR1 via systemctl kill may be lost; reopen ensures the FD swap is committed.
        systemctl kill --kill-who=main -s USR1 nginx.service >/dev/null 2>&1 \
          || nginx -s reopen >/dev/null 2>&1 || true
    endscript
}
EOF
  # [v2.8 Gemini-Doc2-🟠] journald cap: transit nginx workers now log to journal; without a
  # size ceiling the default 1 GB cap on low-disk VPS can still fill and OOM-kill nginx workers.
  # purge_all() removes this drop-in during uninstall.
  local _jd_conf="/etc/systemd/journald.conf.d/transit-manager.conf"
  mkdir -p "/etc/systemd/journald.conf.d"
  # Always rewrite so re-runs update the value if the file already exists from a prior version.
  atomic_write "$_jd_conf" 644 root:root <<'JDEOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
JDEOF
  systemctl restart systemd-journald 2>/dev/null || true
  success "logrotate 已配置；journald 上限已设 SystemMaxUse=200M"
}

init_nginx_stream(){
  # BUG-T2 FIX: nginx -t 引用 error_log 路径，若目录不存在则报 "No such file or directory"
  # 必须在 nginx -t 前创建日志目录并设置正确权限
  local _log_user _log_group
  _log_user="$(_nginx_log_user)"
  _log_group="$(_nginx_log_group)"
  mkdir -p "$LOG_DIR"
  chown root:"$_log_group" "$LOG_DIR" 2>/dev/null || true
  chmod 750 "$LOG_DIR"
  
  # [BUG #38 FIX] 创建日志文件并设置 www-data 可写权限
  # Nginx worker 进程以 www-data 用户运行，需要写入权限
  touch "${LOG_DIR}/transit_stream_error.log"
  chown "${_log_user}:${_log_group}" "${LOG_DIR}/transit_stream_error.log"
  chmod 640 "${LOG_DIR}/transit_stream_error.log"
  
  mkdir -p "$SNIPPETS_DIR" "$CONF_DIR"
  chmod 700 "$SNIPPETS_DIR"
  rm -f "${SNIPPETS_DIR}/landing_dummy.map" "${SNIPPETS_DIR}/landing_*.map.tmp" 2>/dev/null || true

  local _rewrite_existing=0 _had_stream_conf=0 _stream_bak=""
  if _main_stream_include_valid; then
    if _stream_conf_valid; then
      ensure_fallback_blackhole || return 1
      info "Nginx stream include 已存在，跳过"; return 0
    fi
    warn "Nginx stream 配置缺失或漂移，重写本脚本管理的 stream 配置"
    _rewrite_existing=1
  elif grep -q "$STREAM_INCLUDE_MARKER" "$NGINX_MAIN_CONF" 2>/dev/null; then
    warn "Nginx stream include 标记存在但真实 include 行缺失，重写 include"
  fi
  if grep -qE '^[[:space:]]*stream[[:space:]]*\{' "$NGINX_MAIN_CONF" 2>/dev/null; then
    die "nginx.conf 已存在 stream{} 块（非本脚本），请备份后手动删除再运行"
  fi

  info "写入 Nginx stream 透传配置 ..."

  # [审查者1-高危2修复] 删除so_keepalive随机化 - 固定的非标定时器比默认值更显眼
  # 回归系统默认是最好的伪装,让nginx表现得像普通的高并发Web服务器

  # [v2.11 Doc9-B-🟠] Dynamic zone size: 64m fixed consumed ~12% of RAM on a 512MB VPS.
  # Scale to ~3% of RAM (RAM/32), floor 5m (~100k IPs), cap 64m (~1.3M IPs).
  local _stream_ram_mb; _stream_ram_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $2}'); _stream_ram_mb=${_stream_ram_mb:-1024}
  local _stream_zone_mb=$(( _stream_ram_mb / 32 ))
  (( _stream_zone_mb < 5  )) && _stream_zone_mb=5
  (( _stream_zone_mb > 64 )) && _stream_zone_mb=64

  if (( _rewrite_existing )) && [[ -f "$NGINX_STREAM_CONF" ]]; then
    _had_stream_conf=1
    _stream_bak=$(mktemp "${NGINX_STREAM_CONF}.bak.XXXXXX" 2>/dev/null) \
      || die "mktemp stream backup failed"
    cp -f "$NGINX_STREAM_CONF" "$_stream_bak" \
      || die "snapshot stream conf failed"
  fi

  # 空/无匹配/畸形 SNI → 本地黑洞，无外部 DNS 查询。
  atomic_write "$NGINX_STREAM_CONF" 644 root:root <<NGINX_STREAM_EOF
# stream-transit.conf — 由 install_transit.sh 管理，请勿手动修改
# 有效落地机 SNI → 落地机 IP:PORT；无效/空/畸形 SNI → 本地黑洞。
stream {
    access_log off;
    error_log  ${LOG_DIR}/transit_stream_error.log emerg;

    # v2.48: 删 resolver（纯本地 fallback 无需 DNS，消除 GFW 可观测的 DNS 查询）

    # BUG-T1 FIX: limit_req_zone/limit_req 是 HTTP 模块专属指令，stream 模块不支持
    # 已移除 limit_req_zone 和 limit_req；连接数限制由 limit_conn 负责（stream 原生支持）
    # [v2.11] Dynamic zone size: ~3% of host RAM, floor 5m, cap 64m
    limit_conn_zone \$binary_remote_addr zone=transit_stream_conn:${_stream_zone_mb}m;

    # 未匹配 SNI 统一送入本地黑洞，避免外部 fallback 产生额外可观测特征。
    # 使用least_conn策略,自动选择连接数最少的后端
    # [T-MEDIUM-2] 改为本地黑洞 - 避免GFW探测时TCP RST暴露代理特征
    upstream fallback_blackhole {
        server 127.0.0.1:9999;
    }

    # v2.48: SNI 守卫内嵌到 map——超长(≥254字节)/含控制字符/空/无匹配 → 本地 decoy
    map \$ssl_preread_server_name \$backend_upstream {
        hostnames;
        include /etc/nginx/stream-snippets/landing_*.map;
        # [审查者2 Fix] Fallback to blackhole for invalid SNI
        "~^.{254,}"      fallback_blackhole;
        "~[\x00-\x1F]" fallback_blackhole;
        ""               fallback_blackhole;
        default          fallback_blackhole;
    }

    server {
        listen      ${LISTEN_PORT} backlog=65535;
        ssl_preread on;
        preread_buffer_size 64k;  # [fix] 防止 uTLS 庞大 ClientHello 导致 SNI 嗅探失败
        # [C1] Nginx超时配置优化 - 中国到美西高延迟,30s握手+600s传输
        preread_timeout        30s;
        proxy_pass             \$backend_upstream;
        proxy_connect_timeout  30s;
        proxy_timeout          600s;
        proxy_socket_keepalive on;
        tcp_nodelay            on;
        # [F2] 100 per IP: gRPC multiplexes all streams over few TCP connections;
        # 2000 per IP + 315s timeout = slow-drain DoS from just 50 distributed IPs.
        limit_conn transit_stream_conn 100;
    }
}
NGINX_STREAM_EOF

  if _main_stream_include_valid; then
    if ! nginx -t 2>&1; then
      if (( _rewrite_existing )); then
        if (( _had_stream_conf )) && [[ -f "${_stream_bak:-}" ]]; then
          mv -f "$_stream_bak" "$NGINX_STREAM_CONF" 2>/dev/null || true
        else
          rm -f "$NGINX_STREAM_CONF" 2>/dev/null || true
        fi
      fi
      die "Nginx stream 配置重写失败，旧配置已恢复，请检查以上报错"
    fi
    rm -f "${_stream_bak:-}" 2>/dev/null || true
    success "Nginx stream 配置已重写（空/无匹配SNI→本地黑洞）"
    return 0
  fi

  # Bug 37 FIX: 严禁用 sed -i '$a \n...' —— Ubuntu 某些版本将 \n 识别为字母 n
  # 改用 printf + >> 方式追加到临时文件后 mv，纯 POSIX，无环境差异
  local _mc_bak="${NGINX_MAIN_CONF}.transit.bak_$(date +%s)"
  cp -f "$NGINX_MAIN_CONF" "$_mc_bak" 2>/dev/null || true
  ls -t "${NGINX_MAIN_CONF}.transit.bak_"* 2>/dev/null | tail -n +3 | xargs -r rm -f 2>/dev/null || true
  mkdir -p "${NGINX_MAIN_CONF%/*}" || die "mkdir nginx conf dir failed"
  local _mc_tmp; _mc_tmp=$(mktemp "${NGINX_MAIN_CONF%/*}/.snap-recover.XXXXXX" 2>/dev/null) \
    || die "mktemp _mc_tmp failed"
  [[ -n "$_mc_tmp" ]] || die "mktemp returned empty path"
  cp -f "$NGINX_MAIN_CONF" "$_mc_tmp" \
    || die "snapshot nginx.conf failed"
  sed -i "\#${STREAM_INCLUDE_MARKER}#d" "$_mc_tmp" 2>/dev/null || true
  sed -i "\#include ${NGINX_STREAM_CONF};#d" "$_mc_tmp" 2>/dev/null || true
  printf '\n# %s\n' "$STREAM_INCLUDE_MARKER"  >> "$_mc_tmp"
  printf 'include %s;\n'    "$NGINX_STREAM_CONF" >> "$_mc_tmp"
  chmod 644 "$_mc_tmp" \
    || die "chmod _mc_tmp failed"
  mv -f "$_mc_tmp" "$NGINX_MAIN_CONF" \
    || die "promote _mc_tmp to nginx.conf failed"
  # 验证注入成功
  _main_stream_include_valid \
    || die "nginx.conf include 注入失败，请检查文件权限: ${NGINX_MAIN_CONF}"

  if ! nginx -t 2>/dev/null; then
    nginx -t 2>&1 || true
    [[ -f "$_mc_bak" ]] && mv -f "$_mc_bak" "$NGINX_MAIN_CONF" 2>/dev/null || true
    die "Nginx stream 配置验证失败；nginx.conf 已从快照还原"
  fi
  success "Nginx stream 配置写入完成（空/无匹配SNI→本地黑洞 · 回归系统默认参数）"
}

# [S1-HIGH] 增强健康检查 - 自动检测和恢复服务异常
setup_health_check_transit(){
  info "配置健康检查和自动恢复..."
  
  atomic_write "/usr/local/bin/transit-health-check.sh" 755 root:root <<'HEALTH'
#!/bin/bash
# [S1-HIGH] 健康检查脚本 - 确保长期稳定运行
set -euo pipefail

# 检查 Nginx 服务状态
if ! systemctl is-active --quiet nginx; then
  logger -t transit-health "Nginx服务异常,尝试重启"
  systemctl restart nginx
  exit 0
fi

# [S1-T] 检查监听端口 - 中转机端口固定为443
LISTEN_PORT=443
if ! timeout 3 bash -c "</dev/tcp/127.0.0.1/${LISTEN_PORT}" 2>/dev/null; then
  logger -t transit-health "端口${LISTEN_PORT}无响应,重启服务"
  systemctl restart nginx
  exit 0
fi

if [[ ! -f /etc/nginx/conf.d/transit-fallback.conf ]]; then
  logger -t transit-health "SNI黑洞配置缺失,重建并重载Nginx"
  mkdir -p /etc/nginx/conf.d
  cat >/etc/nginx/conf.d/transit-fallback.conf <<'FALLBACK'
# transit-manager: local SNI blackhole
server {
    listen 127.0.0.1:9999 ssl;
    ssl_reject_handshake on;
}
FALLBACK
  nginx -t >/dev/null 2>&1 && { systemctl reload nginx 2>/dev/null || systemctl restart nginx; }
elif ! ss -H -tln 2>/dev/null | awk '$4=="127.0.0.1:9999"{ok=1} END{exit !ok}'; then
  logger -t transit-health "SNI黑洞监听缺失,尝试重启Nginx"
  systemctl restart nginx
fi

# 检查TCP 443规则
if ! iptables -L TRANSIT-MANAGER -n 2>/dev/null | grep -q "ACCEPT.*tcp.*dpt:443"; then
  logger -t transit-health "防火墙443规则丢失,尝试恢复"
  /etc/transit_manager/firewall-restore.sh 2>/dev/null || true
fi

# 检查UDP 443 DROP规则（QUIC防护）
if ! iptables -L TRANSIT-MANAGER -n 2>/dev/null | grep -q "DROP.*udp.*dpt:443"; then
  logger -t transit-health "防火墙UDP 443规则丢失,尝试恢复"
  /etc/transit_manager/firewall-restore.sh 2>/dev/null || true
fi

# 检查INPUT跳转规则
if ! iptables -L INPUT -n 2>/dev/null | grep -q "TRANSIT-MANAGER"; then
  logger -t transit-health "INPUT跳转规则丢失,尝试恢复"
  /etc/transit_manager/firewall-restore.sh 2>/dev/null || true
fi

# 检查 Nginx 配置完整性
if ! nginx -t 2>/dev/null; then
  logger -t transit-health "Nginx配置损坏,尝试恢复"
  systemctl restart nginx
  exit 0
fi
HEALTH

  # [T-M1] 健康检查频率优化 - 从3分钟改为30分钟,长期稳定运行减少日志
  atomic_write "/etc/cron.d/transit-health" 644 root:root <<CRON
# [T-M1] 健康检查 - 每30分钟执行,CN2 GIA线路稳定性好
*/30 * * * * root /usr/local/bin/transit-health-check.sh >/dev/null 2>&1
CRON


  success "健康检查已配置: 每30分钟自动检测"
}

# [M2 Fix] Check for empty meta files before processing
_meta_file_valid(){
  local _mf="$1"
  [[ -f "$_mf" && -s "$_mf" ]] || return 1
  return 0
}

remove_landing_snippet(){
  local domain="$1"
  local safe; safe=$(domain_to_safe "$domain")
  local removed=0 failed=0
  for f in "${SNIPPETS_DIR}/landing_${safe}.map" \
            "${SNIPPETS_DIR}/landing_${safe}.upstream" \
            "${CONF_DIR}/${safe}.meta"; do
    if [[ -f "$f" ]]; then
      if rm -f "$f"; then
        (( ++removed )) || true
      else
        warn "删除路由片段失败: $f"
        failed=1
      fi
    fi
  done
  (( failed == 0 )) || return 1
  (( removed > 0 )) && success "已删除路由片段: ${domain}" \
    || { warn "未找到路由配置: ${domain}"; return 1; }
}

nginx_reload(){
  # BUG-T2 FIX: 确保日志目录存在，防止 nginx -t 因 error_log 路径不存在而失败
  mkdir -p "$LOG_DIR"
  ensure_fallback_blackhole || return 1
  info "验证 Nginx 配置 ..."
  nginx -t 2>&1 || { error "Nginx 配置验证失败，请检查以上报错"; return 1; }
  info "热重载 Nginx ..."
  if systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx || { error "Nginx reload 失败，运行态未生效"; return 1; }
  else
    systemctl restart nginx 2>/dev/null || { error "Nginx restart 失败，运行态未生效"; return 1; }
  fi
  sleep 1
  _fallback_blackhole_ok || { error "fallback 黑洞端口 127.0.0.1:9999 未监听，请检查 Nginx conf.d include 或端口占用"; return 1; }
  success "Nginx 热重载成功（零中断）"
}


setup_firewall_transit(){
  local ssh_port; ssh_port="$(detect_ssh_port)"
  info "配置防火墙 chain ${FW_CHAIN}: SSH(${ssh_port}) + TCP(${LISTEN_PORT}) + ICMP，其余 DROP ..."

  local FW_TMP="${FW_CHAIN}-NEW"
  local FW_OLD="${FW_CHAIN}-OLD"
  local _persist_script="${MANAGER_BASE}/firewall-restore.sh"
  local _snap_persist=""
  local _had_old=0 _fw_swapped=0
  mkdir -p "${MANAGER_BASE}/tmp"
  if [[ -f "$_persist_script" ]]; then
    _snap_persist=$(mktemp "${MANAGER_BASE}/tmp/fw-restore.XXXXXX") \
      || die "mktemp _snap_persist failed"
    cp -f "$_persist_script" "$_snap_persist" \
      || { rm -f "$_snap_persist" 2>/dev/null || true; die "snapshot firewall-restore.sh failed"; }
  fi

  # iptables -E 遇到 INPUT 中任何目标链引用都会失败；按行号倒序删除引用后再切链。
_bulldoze_input_refs_t(){
    local _chain="$1" _lines _n
    mapfile -t _lines < <(iptables -w 2 -L INPUT --line-numbers -n 2>/dev/null | awk -v c="$_chain" '$2==c {print $1}' | sort -rn)
    for _n in "${_lines[@]}"; do
      iptables -w 2 -D INPUT "$_n" 2>/dev/null || true
    done
  }
  _bulldoze_input_refs_t "$FW_TMP"; _bulldoze_input_refs_t "$FW_OLD"
  iptables -w 2 -F "$FW_TMP"   2>/dev/null || true; iptables -w 2 -X "$FW_TMP"   2>/dev/null || true
  iptables -w 2 -F "$FW_OLD"   2>/dev/null || true; iptables -w 2 -X "$FW_OLD"   2>/dev/null || true

  local _prev_err_trap _prev_int_trap _prev_term_trap
  _prev_err_trap=$(trap -p ERR || true)
  _prev_int_trap=$(trap -p INT || true)
  _prev_term_trap=$(trap -p TERM || true)
  _fw_transit_rollback(){
    _bulldoze_input_refs_t "$FW_TMP"
    while iptables -w 2 -D INPUT -m comment --comment "transit-manager-swap" 2>/dev/null; do :; done
    _bulldoze_input_refs_t "$FW_CHAIN"
    if iptables -w 2 -S "$FW_OLD" >/dev/null 2>&1; then
      iptables -w 2 -F "$FW_CHAIN" 2>/dev/null || true
      iptables -w 2 -X "$FW_CHAIN" 2>/dev/null || true
      iptables -w 2 -E "$FW_OLD" "$FW_CHAIN" 2>/dev/null || true
      iptables -w 2 -I INPUT 1 -m comment --comment "transit-manager-rule" -j "$FW_CHAIN" 2>/dev/null || true
    elif (( _fw_swapped == 0 )) && iptables -w 2 -S "$FW_CHAIN" >/dev/null 2>&1; then
      iptables -w 2 -I INPUT 1 -m comment --comment "transit-manager-rule" -j "$FW_CHAIN" 2>/dev/null || true
    else
      iptables -w 2 -F "$FW_CHAIN" 2>/dev/null || true
      iptables -w 2 -X "$FW_CHAIN" 2>/dev/null || true
    fi
    iptables -w 2 -F "$FW_TMP" 2>/dev/null || true
    iptables -w 2 -X "$FW_TMP" 2>/dev/null || true
    # v2.36 GPT: 区分"有旧快照"和"首次安装无旧文件"两种情形
    if [[ -n "${_snap_persist:-}" && -f "${_snap_persist:-}" ]]; then
      # 存在旧快照 → 还原
      mv -f "$_snap_persist" "$_persist_script" 2>/dev/null || true
    else
      # 首次安装 → 无旧脚本可还原，删除新生成的脚本和 unit，防半装状态带入开机
      rm -f "$_persist_script" 2>/dev/null || true
      systemctl disable --now transit-manager-iptables-restore.service 2>/dev/null || true
      rm -f "/etc/systemd/system/transit-manager-iptables-restore.service" 2>/dev/null || true
      systemctl daemon-reload 2>/dev/null || warn "daemon-reload 失败，请稍后手动执行 systemctl daemon-reload"
    fi
    _snap_persist=""
  }
  _restore_prev_traps(){
    eval "${_prev_err_trap:-trap - ERR}"
    eval "${_prev_int_trap:-trap - INT}"
    eval "${_prev_term_trap:-trap - TERM}"
  }
  trap '_fw_transit_rollback; _restore_prev_traps; exit 1' ERR
  trap '_fw_transit_rollback; _restore_prev_traps; exit 130' INT TERM
  iptables -w 2 -N "$FW_TMP" 2>/dev/null || iptables -w 2 -F "$FW_TMP"
  # v2.32 Grok: lo + SSH 先于 INVALID,UNTRACKED 放行，保证 conntrack 表满时 SSH 仍可新建连接
  iptables -w 2 -A "$FW_TMP" -i lo                                       -m comment --comment "transit-manager-rule" -j ACCEPT
  iptables -w 2 -A "$FW_TMP" -p tcp  --dport "$ssh_port"                 -m comment --comment "transit-manager-rule" -j ACCEPT
  iptables -w 2 -A "$FW_TMP" -m conntrack --ctstate INVALID,UNTRACKED    -m comment --comment "transit-manager-rule" -j DROP
  iptables -w 2 -A "$FW_TMP" -m conntrack --ctstate ESTABLISHED,RELATED  -m comment --comment "transit-manager-rule" -j ACCEPT
  iptables -w 2 -A "$FW_TMP" -p icmp --icmp-type echo-request -m limit --limit 10/second --limit-burst 20 \
                                                                     -m comment --comment "transit-manager-rule" -j ACCEPT
  iptables -w 2 -A "$FW_TMP" -p icmp --icmp-type echo-request            -m comment --comment "transit-manager-rule" -j DROP
  # v4.41: 显式阻断 UDP 443（QUIC 流量），强制客户端降级到 TCP
  iptables -w 2 -A "$FW_TMP" -p udp  --dport "$LISTEN_PORT"              -m comment --comment "transit-manager-rule" -j DROP
  # v1.3: 明确 ACCEPT 新建 443 连接（connlimit/rate 只拦 DDoS，正常流量必须先过这一关）
  # 规则顺序：① connlimit（超并发 DROP）→ ② rate（超速率 DROP）→ ③ ACCEPT 剩余正常 443 新连接
  iptables -w 2 -A "$FW_TMP" -p tcp  --dport "$LISTEN_PORT" \
    -m connlimit --connlimit-above 2000 --connlimit-mask 32        -m comment --comment "transit-manager-rule" -j DROP
  iptables -w 2 -A "$FW_TMP" -p tcp  --dport "$LISTEN_PORT" \
    -m connlimit --connlimit-above 20000 --connlimit-mask 0        -m comment --comment "transit-manager-rule" -j DROP
  # [v5.18-T-HIGH-1] 先删除可能存在的旧规则，避免重复
  # [v5.22-CRITICAL-1] 使用-A追加hashlimit规则,确保在connlimit之后、DROP之前
  iptables -w 2 -A "$FW_TMP" -p tcp  --dport "$LISTEN_PORT" \
    -m hashlimit --hashlimit-upto 8000/sec --hashlimit-burst 9999 --hashlimit-mode srcip --hashlimit-name transit_443_limit -m comment --comment "transit-manager-rule" -j ACCEPT
  # 超速率的 443 DROP（rate 令牌耗尽时走此规则）
  iptables -w 2 -A "$FW_TMP" -p tcp  --dport "$LISTEN_PORT"              -m comment --comment "transit-manager-rule" -j DROP
  iptables -w 2 -A "$FW_TMP"                                              -m comment --comment "transit-manager-rule" -j DROP
  if ! _persist_iptables "$ssh_port"; then
    _fw_transit_rollback
    _restore_prev_traps
    die "防火墙持久化失败（firewall-restore.sh/unit 写入异常），运行链未切换"
  fi

  iptables -w 2 -S "$FW_CHAIN" >/dev/null 2>&1 && _had_old=1 || _had_old=0
  iptables -w 2 -I INPUT 1 -m comment --comment "transit-manager-swap" -j "$FW_TMP"
  _bulldoze_input_refs_t "$FW_CHAIN"
  if (( _had_old )); then
    iptables -w 2 -E "$FW_CHAIN" "$FW_OLD" \
      || { _fw_transit_rollback; _restore_prev_traps; die "防火墙旧链快照失败，已保留原运行链"; }
  fi
  iptables -w 2 -E "$FW_TMP" "$FW_CHAIN" \
    || { _fw_transit_rollback; _restore_prev_traps; die "防火墙新链切换失败，已回滚旧运行链"; }
  _fw_swapped=1
  iptables -w 2 -I INPUT 1 -m comment --comment "transit-manager-rule" -j "$FW_CHAIN"
  # [R5 Fix] Verify INPUT position 1 — warn (not die) since Docker/fail2ban also use position 1
  local _actual_pos
  _actual_pos=$(iptables -w 2 -L INPUT --line-numbers -n 2>/dev/null | awk -v c="$FW_CHAIN" '$2==c {print $1; exit}')
  if [[ "${_actual_pos:-}" != "1" ]]; then
    warn "防火墙规则未能在 INPUT 链首位（实际位置: ${_actual_pos:-?}），可能与其他服务冲突"
  fi
  iptables -w 2 -C "$FW_CHAIN" -p udp --dport "$LISTEN_PORT" -m comment --comment "transit-manager-rule" -j DROP \
    || { _fw_transit_rollback; _restore_prev_traps; die "UDP 443 DROP 规则未生效，拒绝提交防火墙状态"; }
  while iptables -w 2 -D INPUT -m comment --comment "transit-manager-swap" 2>/dev/null; do :; done
  iptables -w 2 -F "$FW_OLD" 2>/dev/null || true
  iptables -w 2 -X "$FW_OLD" 2>/dev/null || true
  _restore_prev_traps
  rm -f "${_snap_persist:-}" 2>/dev/null || true
  
  success "UDP 443（QUIC）封堵规则已生效"
  
}


_persist_iptables(){
  local ssh_port="${1:-22}"
  # [R6 Fix] Validate ssh_port is numeric before template injection
  [[ "$ssh_port" =~ ^[0-9]+$ ]] || { error "SSH 端口非法（需为数字）: $ssh_port"; return 1; }
  (( ssh_port >= 1 && ssh_port <= 65535 )) || { error "SSH 端口超范围 (1-65535): $ssh_port"; return 1; }
  # [R22 Fix] Validate FW_CHAIN names contain only safe characters before template injection
  [[ "$FW_CHAIN" =~ ^[A-Za-z0-9_-]+$ ]] || { error "FW_CHAIN 含非法字符: $FW_CHAIN"; return 1; }
  mkdir -p "$MANAGER_BASE" || { error "mkdir ${MANAGER_BASE} failed"; return 1; }
  local fw_script="${MANAGER_BASE}/firewall-restore.sh"
  local _fw_sig="TRANSIT_FW_VERSION=${VERSION}_$(date +%Y%m%d)"
  # [BUG-7-FIX] 导出环境变量供Python脚本使用
  # [BUG-9-FIX] readonly变量不能重新赋值，只能export
  export FW_CHAIN
  export FW_SIG="$_fw_sig"
  export SSH_PORT_FALLBACK="$ssh_port"
  export LISTEN_PORT
  python3 - <<'PY' | atomic_write "$fw_script" 700 root:root || return 1
import os, sys

template = r"""#!/usr/bin/env bash
set -euo pipefail
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || { echo "ERROR: Bash 4+ required"; exit 1; }
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# __FW_SIG__
# 🟠 Grok: SSH 端口在恢复时动态探测，防止用户修改 sshd 端口后重启丢失 SSH
_detect_ssh(){
  local p=""
  p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  [ -z "$p" ] && p="$(ss -H -tlnp 2>/dev/null | awk '
    $1=="LISTEN" && /sshd/ {
      addr=$4
      sub(/^.*:/,"",addr)
      gsub(/^\[/,"",addr)
      gsub(/\]$/,"",addr)
      if (addr ~ /^[0-9]+$/) { print addr; exit }
    }' || true)"
  # [R12 Fix] sshd not running at boot → fall back to sshd_config before using install-time value
  [ -z "$p" ] && p="$(grep -RhsE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null | awk '{print $2}' | sort -n | head -1 || true)"
  _ssh_port="${p:-}"; [[ -z "$_ssh_port" || "$_ssh_port" == "0" ]] && _ssh_port=__SSH_PORT__
  if echo "$_ssh_port" | grep -qE '^[0-9]+$' && [ "$_ssh_port" -ge 1 ] && [ "$_ssh_port" -le 65535 ]; then
    echo "$_ssh_port"
  else
    # [C1 Fix] Remove exit 1 - fallback to install-time port instead of blocking firewall restore
    logger -t transit-firewall "WARN: 无法动态探测 SSH 端口，使用安装时值 __SSH_PORT__"
    echo "__SSH_PORT__"
  fi
}
SSH_PORT="$(_detect_ssh)"
_bulldoze_input_refs(){
    local _chain="$1" _lines _n
    mapfile -t _lines < <(iptables -w 2 -L INPUT --line-numbers -n 2>/dev/null | awk -v c="$_chain" '$2==c {print $1}' | sort -rn)
    for _n in "${_lines[@]}"; do
      iptables -w 2 -D INPUT "$_n" 2>/dev/null || true
    done
  }
_rollback(){
  while iptables -w 2 -D INPUT -m comment --comment "transit-manager-swap" 2>/dev/null; do :; done
  _bulldoze_input_refs __FW_CHAIN__
  if iptables -w 2 -S __FW_CHAIN__-OLD >/dev/null 2>&1; then
    iptables -w 2 -F __FW_CHAIN__ 2>/dev/null || true
    iptables -w 2 -X __FW_CHAIN__ 2>/dev/null || true
    iptables -w 2 -E __FW_CHAIN__-OLD __FW_CHAIN__ 2>/dev/null || true
    iptables -w 2 -I INPUT 1 -m comment --comment "transit-manager-rule" -j __FW_CHAIN__ 2>/dev/null || true
  elif iptables -w 2 -S __FW_CHAIN__ >/dev/null 2>&1; then
    iptables -w 2 -I INPUT 1 -m comment --comment "transit-manager-rule" -j __FW_CHAIN__ 2>/dev/null || true
  fi
  iptables -w 2 -F __FW_CHAIN__-NEW 2>/dev/null || true
  iptables -w 2 -X __FW_CHAIN__-NEW 2>/dev/null || true
}
_bulldoze_input_refs __FW_CHAIN__-NEW
_bulldoze_input_refs __FW_CHAIN__-OLD
iptables -w 2 -F __FW_CHAIN__-OLD 2>/dev/null || true
iptables -w 2 -X __FW_CHAIN__-OLD 2>/dev/null || true
iptables -w 2 -N __FW_CHAIN__-NEW 2>/dev/null || true
iptables -w 2 -F __FW_CHAIN__-NEW 2>/dev/null || true
iptables -w 2 -A __FW_CHAIN__-NEW -i lo                                       -m comment --comment "transit-manager-rule" -j ACCEPT
iptables -w 2 -A __FW_CHAIN__-NEW -p tcp  --dport ${SSH_PORT}                -m comment --comment "transit-manager-rule" -j ACCEPT
iptables -w 2 -A __FW_CHAIN__-NEW -m conntrack --ctstate INVALID,UNTRACKED    -m comment --comment "transit-manager-rule" -j DROP
iptables -w 2 -A __FW_CHAIN__-NEW -m conntrack --ctstate ESTABLISHED,RELATED  -m comment --comment "transit-manager-rule" -j ACCEPT
iptables -w 2 -A __FW_CHAIN__-NEW -p icmp --icmp-type echo-request -m limit --limit 10/second --limit-burst 20 -m comment --comment "transit-manager-rule" -j ACCEPT
iptables -w 2 -A __FW_CHAIN__-NEW -p icmp --icmp-type echo-request            -m comment --comment "transit-manager-rule" -j DROP
iptables -w 2 -A __FW_CHAIN__-NEW -p udp  --dport __LISTEN_PORT__             -m comment --comment "transit-manager-rule" -j DROP
iptables -w 2 -A __FW_CHAIN__-NEW -p tcp  --dport __LISTEN_PORT__ -m connlimit --connlimit-above 2000 --connlimit-mask 32 -m comment --comment "transit-manager-rule" -j DROP
iptables -w 2 -A __FW_CHAIN__-NEW -p tcp  --dport __LISTEN_PORT__ -m connlimit --connlimit-above 20000 --connlimit-mask 0  -m comment --comment "transit-manager-rule" -j DROP
iptables -w 2 -A __FW_CHAIN__-NEW -p tcp  --dport __LISTEN_PORT__ -m hashlimit --hashlimit-upto 8000/sec --hashlimit-burst 9999 --hashlimit-mode srcip --hashlimit-name transit_443_limit             -m comment --comment "transit-manager-rule" -j ACCEPT
iptables -w 2 -A __FW_CHAIN__-NEW -p tcp  --dport __LISTEN_PORT__                                                         -m comment --comment "transit-manager-rule" -j DROP
iptables -w 2 -A __FW_CHAIN__-NEW                                              -m comment --comment "transit-manager-rule" -j DROP
_had_old=0
iptables -w 2 -S __FW_CHAIN__ >/dev/null 2>&1 && _had_old=1 || _had_old=0
iptables -w 2 -I INPUT 1 -m comment --comment "transit-manager-swap" -j __FW_CHAIN__-NEW
_bulldoze_input_refs __FW_CHAIN__
if [ "$_had_old" = 1 ]; then
  iptables -w 2 -E __FW_CHAIN__ __FW_CHAIN__-OLD 2>/dev/null || { _rollback; exit 1; }
fi
iptables -w 2 -E __FW_CHAIN__-NEW __FW_CHAIN__ 2>/dev/null || {
  _rollback
  exit 1
}
iptables -w 2 -I INPUT 1 -m comment --comment "transit-manager-rule" -j __FW_CHAIN__
while iptables -w 2 -D INPUT -m comment --comment "transit-manager-swap" 2>/dev/null; do :; done
iptables -w 2 -F __FW_CHAIN__-OLD 2>/dev/null || true
iptables -w 2 -X __FW_CHAIN__-OLD 2>/dev/null || true
"""
template = template.replace("__FW_SIG__", os.environ["FW_SIG"])
template = template.replace("__SSH_PORT__", os.environ["SSH_PORT_FALLBACK"])
template = template.replace("__FW_CHAIN__", os.environ["FW_CHAIN"])
template = template.replace("__LISTEN_PORT__", os.environ["LISTEN_PORT"])
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
sys.stdout.write(template)
PY
  local rsvc="/etc/systemd/system/transit-manager-iptables-restore.service"
  atomic_write "$rsvc" 644 root:root <<RSTO || return 1
[Unit]
Description=Restore iptables rules for transit-manager
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=${fw_script}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
RSTO
  systemctl daemon-reload \
    || { error "systemctl daemon-reload failed — iptables-restore service unit may not load"; return 1; }
  systemctl enable transit-manager-iptables-restore.service \
    || { error "iptables 持久化服务 enable 失败，重启后防火墙规则将丢失"; return 1; }
  systemctl is-enabled --quiet transit-manager-iptables-restore.service \
    || { error "iptables 持久化服务 enabled 状态验收失败"; return 1; }
}

# 原子提交路由（map + meta + nginx reload 三合一）
# 正常路径: snapshot → write_map → nginx-t → write_meta → reload → clean
# 失败路径: 任一步骤失败 → restore_map → reload_restore → die
# v2.38 Gemini: .map mv 后立即挂局部 INT/TERM trap，防中断产生"幽灵 .map"（无 .meta 对应）
_atomic_apply_route(){
  # ARCH-2 FIX: 新增 uuid/pwd/pfx 三个参数；meta 存储全量字段供 generate_nodes() 使用
  # v2.39: 先定义函数再注册trap，防止ERR触发时函数未定义
  # [C1 Fix] Initialize exported vars BEFORE trap registration to prevent empty-string mv on ERR
  export _ROUTE_MAP_TARGET="" _ROUTE_META_TARGET=""
  export _ROUTE_SNAP_MAP="" _ROUTE_SNAP_META=""
  export __ROUTE_ROLLBACK_ACTIVE=1
  # [R1 Fix] Use exported global vars so rollback works when ERR fires from subshell
  _route_rollback(){
    [[ "${__ROUTE_ROLLBACK_ACTIVE:-0}" == "1" ]] || return 0
    __ROUTE_ROLLBACK_ACTIVE=0
    local _map_target="${_ROUTE_MAP_TARGET:-}" _meta_target="${_ROUTE_META_TARGET:-}"
    local _snap_map_path="${_ROUTE_SNAP_MAP:-}" _snap_meta_path="${_ROUTE_SNAP_META:-}"
    if [[ -n "$_snap_map_path" && -f "$_snap_map_path" && -n "$_map_target" ]]; then
      mv -f "$_snap_map_path" "$_map_target" 2>/dev/null || true
    elif [[ -n "$_map_target" ]]; then
      rm -f "$_map_target" 2>/dev/null || true
    fi
    if [[ -n "$_snap_meta_path" && -f "$_snap_meta_path" && -n "$_meta_target" ]]; then
      mv -f "$_snap_meta_path" "$_meta_target" 2>/dev/null || true
    elif [[ -n "$_meta_target" ]]; then
      rm -f "$_meta_target" 2>/dev/null || true
    fi
    if ! nginx -t 2>/dev/null; then
      echo "[WARN] _route_rollback: nginx -t 失败" >&2
    elif ! { systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null; }; then
      echo "[WARN] _route_rollback: nginx reload/restart 失败，运行态可能未回滚" >&2
    fi
    rm -f "${_snap_map_path:-}" "${_snap_meta_path:-}" 2>/dev/null || true
  }
  local _prev_route_err_trap _prev_route_int_trap _prev_route_term_trap
  _prev_route_err_trap=$(trap -p ERR || true)
  _prev_route_int_trap=$(trap -p INT || true)
  _prev_route_term_trap=$(trap -p TERM || true)
  _restore_prev_route_traps(){
    if [[ -n "${_prev_route_err_trap:-}" ]]; then
      eval "$_prev_route_err_trap" || trap - ERR
    else
      trap - ERR
    fi
    if [[ -n "${_prev_route_int_trap:-}" ]]; then
      eval "$_prev_route_int_trap" || trap - INT
    else
      trap - INT
    fi
    if [[ -n "${_prev_route_term_trap:-}" ]]; then
      eval "$_prev_route_term_trap" || trap - TERM
    else
      trap - TERM
    fi
  }
  trap '_route_rollback; _restore_prev_route_traps; exit 1' INT TERM ERR
  local domain="$1" ip="$2" port="$3"
  local uuid="${4:-}" pwd="${5:-}" pfx="${6:-}"
  local safe; safe=$(domain_to_safe "$domain")
  [[ -n "$safe" ]] || die "域名 safe 转换后为空: ${domain}"

  local map_target="${SNIPPETS_DIR}/landing_${safe}.map"
  local meta_target="${CONF_DIR}/${safe}.meta"

  local _dup_map=""
  _dup_map=$(_route_key_conflict "$domain" "$map_target" 2>/dev/null || true)
  [[ -z "$_dup_map" ]] || die "域名 SNI 键已存在于其他路由片段: ${_dup_map}"

  # 1. 快照旧文件（失败时回滚用）
  local _snap_map="" _snap_meta=""
  mkdir -p "$SNIPPETS_DIR" "$CONF_DIR"
  if [[ -f "$map_target" ]]; then
    _snap_map=$(mktemp "${SNIPPETS_DIR}/.snap-recover.XXXXXX") \
      || die "mktemp _snap_map failed"
    cp -f "$map_target" "$_snap_map" \
      || die "snapshot map_target failed"
  fi
  if [[ -f "$meta_target" ]]; then
    _snap_meta=$(mktemp "${CONF_DIR}/.snap-recover.XXXXXX") \
      || die "mktemp _snap_meta failed"
    cp -f "$meta_target" "$_snap_meta" \
      || die "snapshot meta_target failed"
  fi
  # [R1 Fix] Export globals BEFORE trap fires — ERR trap runs in subshell where
  # local vars are out of scope. Rollback must read stable global copies.
  export _ROUTE_MAP_TARGET="$map_target" _ROUTE_META_TARGET="$meta_target"
  export _ROUTE_SNAP_MAP="$_snap_map" _ROUTE_SNAP_META="$_snap_meta"

  # 2. 写新 .map（原子 mv 到正式路径供 nginx -t）
  local tmp_map; tmp_map=$(mktemp "${SNIPPETS_DIR}/.snap-recover.XXXXXX") \
    || die "mktemp tmp_map failed"
  local _map_key; _map_key=$(nginx_domain_str "$domain")
  [[ -n "$_map_key" && ${#_map_key} -le 200 ]] \
    || { rm -f "$tmp_map" 2>/dev/null; die "域名过滤后为空或超长，拒绝写入 map: ${domain}"; }
  if ! printf '    %s    %s:%s;\n' "$_map_key" "$(nginx_ip_str "$ip")" "$port" > "$tmp_map"; then
    rm -f "$tmp_map" 2>/dev/null || true
    _route_rollback; _restore_prev_route_traps
    die "写入临时 .map 失败，已回滚"
  fi
  if ! chmod 600 "$tmp_map"; then
    rm -f "$tmp_map" 2>/dev/null || true
    _route_rollback; _restore_prev_route_traps
    die "设置临时 .map 权限失败，已回滚"
  fi
  if ! mv -f "$tmp_map" "$map_target"; then
    rm -f "$tmp_map" 2>/dev/null || true
    _route_rollback; _restore_prev_route_traps
    die "提交 .map 失败，已回滚"
  fi
  chmod 600 "$map_target" 2>/dev/null || true

  # 3. nginx -t 验证
  if ! nginx -t 2>/dev/null; then
    _route_rollback; _restore_prev_route_traps
    die "Nginx 语法校验失败，.map 已回滚（真相源未分裂）"
  fi

  # [F3] Write meta BEFORE nginx reload: if meta write fails, the running nginx is still on
  # old map (which we will roll back); prevents truth-source split where nginx routes new IP
  # but .meta is missing. Old order (reload→meta) left a window where nginx served new IP
  # with no truth record on disk-full or permission error.
  # [F3] Collision check: prevent overwriting .meta belonging to a different domain
  local _existing_dom=""; [[ -f "$meta_target" ]] && _existing_dom=$(grep '^DOMAIN=' "$meta_target" 2>/dev/null | cut -d= -f2); [[ -n "$_existing_dom" && "$_existing_dom" != "$domain" ]] && die "Filename collision: $safe already used by $_existing_dom"

  local tmp_meta; tmp_meta=$(mktemp "${CONF_DIR}/.snap-recover.XXXXXX") \
    || die "mktemp tmp_meta failed"
  if ! printf 'DOMAIN=%s\nTRANSIT_IP=%s\nPORT=%s\nUUID=%s\nPWD=%s\nPFX=%s\nCREATED=%s\n' \
    "$domain" "$ip" "$port" "$uuid" "$pwd" "$pfx" "$(date +%Y%m%d_%H%M%S)" > "$tmp_meta"; then
    rm -f "$tmp_meta" 2>/dev/null || true
    _route_rollback; _restore_prev_route_traps
    die "写入临时 .meta 失败，.map 已回滚"
  fi
  if ! chmod 600 "$tmp_meta"; then
    rm -f "$tmp_meta" 2>/dev/null || true
    _route_rollback; _restore_prev_route_traps
    die "设置临时 .meta 权限失败，.map 已回滚"
  fi
  if ! mv -f "$tmp_meta" "$meta_target"; then
    rm -f "$tmp_meta" 2>/dev/null || true
    _route_rollback; _restore_prev_route_traps
    die "meta 原子提交失败，.map 已回滚（真相源未分裂）"
  fi
  chmod 600 "$meta_target" 2>/dev/null || true

  # 4. nginx reload（运行态更新）— meta is already committed; reload failure is now safe to roll back
  if ! nginx_reload; then
    _route_rollback; _restore_prev_route_traps
    die "Nginx 热重载失败，.map 和 .meta 已回滚"
  fi

  _restore_prev_route_traps
  __ROUTE_ROLLBACK_ACTIVE=0
  rm -f "${_snap_map:-}" "${_snap_meta:-}" 2>/dev/null || true
  unset _ROUTE_MAP_TARGET _ROUTE_META_TARGET _ROUTE_SNAP_MAP _ROUTE_SNAP_META __ROUTE_ROLLBACK_ACTIVE
  unset -f _route_rollback _restore_prev_route_traps
  success "路由原子提交: SNI=${domain} → ${ip}:${port}"
}

list_landings(){
  echo ""
  echo -e "${BOLD}── 已配置落地机 ─────────────────────────────────────────────────${NC}"
  local n=0
  while IFS= read -r meta; do
    [[ -f "$meta" ]] || continue
    local dom ip ts port
    dom=$(grep '^DOMAIN='  "$meta" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}' || echo "?")
    ip=$(read_meta_ip "$meta" 2>/dev/null) || ip="?"
    port=$(grep '^PORT='   "$meta" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}') || port=443
    ts=$(grep  '^CREATED=' "$meta" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}' || echo "?")
    printf "  [%d] %-38s → %-20s :%s  创建: %s\n" $((++n)) "$dom" "$ip" "$port" "$ts"
  done < <(find "$CONF_DIR" -name "*.meta" -type f 2>/dev/null | sort)
  [[ $n -eq 0 ]] && warn "（暂无已配置落地机）"
  echo ""
}

# ARCH-2: 利用 meta 中存储的 uuid/pwd/pfx 生成完整 4 协议订阅链接
# transit_ip = 中转机公网 IP；每个 meta 对应一条落地链路的完整节点集
generate_nodes(){
  local transit_ip="${1:-}"
  if [[ -z "$transit_ip" ]]; then
    transit_ip=$(get_public_ip --strict)
  fi
  # [R2 Fix] Validate transit_ip before using it in Python URI generation
  if [[ "$transit_ip" != "<TRANSIT_IP>" ]]; then
    validate_ip "$transit_ip" 2>/dev/null || {
      warn "中转机 IP 格式非法: $transit_ip，跳过节点生成"
      return 1
    }
  fi

  local any=0
  while IFS= read -r meta; do
    # [M2 Fix] Skip empty meta files
    _meta_file_valid "$meta" || { warn "跳过空文件: $meta"; continue; }
    [[ -f "$meta" ]] || continue
    local dom ip port uuid pwd pfx
    dom=$(grep  '^DOMAIN=' "$meta" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}') || continue
    ip=$(read_meta_ip "$meta" 2>/dev/null) || continue
    port=$(grep '^PORT='   "$meta" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}') || port=443
    uuid=$(grep '^UUID='   "$meta" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}') || uuid=""
    pwd=$(grep  '^PWD='    "$meta" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}')  || pwd=""
    pfx=$(grep  '^PFX='    "$meta" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}')  || pfx=""
    [[ -n "$dom" && -n "$ip" ]] || continue

    if [[ -z "$uuid" || -z "$pwd" || -z "$pfx" ]]; then
      warn "节点 ${dom} 缺少 uuid/pwd/pfx（旧版 Token 导入），无法生成订阅节点"
      warn "  → 修复方法："
      warn "     1. 在落地机 ${ip} 上执行脚本，选择菜单选项 6（显示配对信息）"
      warn "     2. 复制该节点的 Base64 Token"
      warn "     3. 在中转机执行: bash \$0 --import '<Token>'"
      warn "  → 影响: 该节点所有协议订阅均不可用，需重新导入新版 Token"
      continue
    fi

    echo ""
    echo -e "${BOLD}${GREEN}── 节点订阅: ${dom} ──────────────────────────────────────────${NC}"
    echo -e "  落地机 IP: ${ip}  端口: ${port}  SNI: ${dom}"
    echo -e "  中转机 IP: ${transit_ip}  (客户端连接此 IP)"
    echo ""

    local sub_b64="" _sub_err="" _tmp=""
    _tmp=$(mktemp) || return 1
    printf '%s\n' "$transit_ip" "$dom" "$uuid" "$pwd" "$pfx" > "$_tmp"
    # [v5.48 CRITICAL-25] Merge two Python calls - first call was missing heredoc, second call discarded output
    # [v5.49-CRITICAL-3] 删除Trojan-gRPC节点，修复Trojan-TCP缺少alpn参数，使用随机指纹
    sub_b64=$(python3 - "$_tmp" 2>&1 <<'PYGEN'
import base64, urllib.parse, sys, random
lines = [l.strip() for l in open(sys.argv[1]).read().split('\n') if l.strip()]
if len(lines) < 5:
    raise SystemExit(1)
ip, domain, vu, tp, pfx = lines[0], lines[1], lines[2], lines[3], lines[4]
port = 443
# [v5.49] 浏览器指纹池随机化 - 与落地机保持一致
fp_pool = ['chrome', 'firefox', 'safari', 'ios', 'android', 'edge', 'random']
random.shuffle(fp_pool)
fp_vision, fp_grpc, fp_ws, fp_tcp = fp_pool[0], fp_pool[1], fp_pool[2], fp_pool[3]
lbl = {'v': '[禁Mux]VLESS-Vision-', 'vg': 'VLESS-gRPC-', 'w': 'VLESS-WS-', 't': 'Trojan-TCP-'}
uris = [
    f'vless://{vu}@{ip}:{port}?encryption=none&flow=xtls-rprx-vision&security=tls&sni={domain}&fp={fp_vision}&type=tcp&mux=0#{urllib.parse.quote(lbl["v"]+domain)}',
    f'vless://{vu}@{ip}:{port}?encryption=none&security=tls&sni={domain}&fp={fp_grpc}&type=grpc&serviceName={pfx}-vg&alpn=h2&mode=multi#{urllib.parse.quote(lbl["vg"]+domain)}',
    f'vless://{vu}@{ip}:{port}?encryption=none&security=tls&sni={domain}&fp={fp_ws}&type=ws&path=%2F{pfx}-vw&host={domain}&alpn=http/1.1#{urllib.parse.quote(lbl["w"]+domain)}',
    # 4. Trojan-TCP (默认fallback，alpn=空显式声明不使用ALPN)
    # 注意：必须显式设置alpn=，否则客户端会自动添加默认ALPN导致无法匹配fallback
    f'trojan://{urllib.parse.quote(tp)}@{ip}:{port}?security=tls&sni={domain}&fp={fp_tcp}&type=tcp&alpn=#{urllib.parse.quote(lbl["t"]+domain)}',
]
print(base64.b64encode('\n'.join(uris).encode()).decode())
PYGEN
) || { _sub_err="$sub_b64"; sub_b64=""; }
    
    # [v5.48 CRITICAL-25] Clean up temp file after Python call
    rm -f "$_tmp"

    if [[ -n "$sub_b64" ]]; then
      echo -e "  ${BOLD}Base64 订阅（粘贴到客户端「添加订阅」）:${NC}"
      echo ""
      echo "  $sub_b64"
      echo ""
      echo -e "  ${CYAN}（Clash Meta / NekoBox / v2rayN / Sing-box / Shadowrocket）${NC}"
      echo -e "  ${RED}${BOLD}⚠  VLESS-Vision 节点【严禁开启 Mux】！开启必断流！${NC}"
    else
      warn "  节点 ${dom} 订阅生成失败"
      [[ -n "${_sub_err:-}" ]] && error "    Python 错误: ${_sub_err}"
    fi
    (( ++any )) || true
  done < <(find "$CONF_DIR" -name "*.meta" -type f 2>/dev/null | sort)

  if (( any == 0 )); then
    warn "无可用节点（meta 文件为空或均缺少 uuid/pwd/pfx）"
  fi
  # [v5.36 CRITICAL-15] Fix: if statement returns 1 when condition is false (any != 0)
  # This caused the entire script to exit with code 1 even when installation succeeded.
  return 0
}

extract_import_token_json_no_deps(){
  local raw="$1"
  [[ -n "$raw" ]] || die "需要 token 参数"
  raw=$(printf '%s' "$raw" | tr -d ' \n\r\t')
  (( ${#raw} <= 2048 )) || die "token 过长（${#raw} 字节），拒绝解析"
  local token=""
  token=$(printf '%s' "$raw" | grep -Eo '(eyJ|eyA)[A-Za-z0-9+/=]{20,}|[A-Za-z0-9+/=]{40,}' | head -1 || true)
  if [[ -z "$token" ]]; then
    die "token 形态非法，请从落地机复制完整的 Base64 导入 token"
  fi
  local pad_len=$(( (4 - ${#token} % 4) % 4 )) pad="" decoded=""
  if (( pad_len > 0 )); then
    printf -v pad '%*s' "$pad_len" ''
    pad=${pad// /=}
  fi
  decoded=$(printf '%s' "${token}${pad}" | base64 -d 2>/dev/null) \
    || die "无法解析 Base64 token，请检查输入"
  printf '%s' "$decoded" | grep -Eq '^[[:space:]]*\{.*\}[[:space:]]*$' \
    || die "token 解码后不是 JSON 对象，请重新从落地机复制完整 token"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$decoded" | python3 -c "
import json
import sys
d = json.loads(sys.stdin.read())
if not isinstance(d, dict) or not d.get('ip') or not d.get('dom'):
    raise SystemExit(1)
" 2>/dev/null || die "token 预校验失败（JSON 畸形或 ip/dom 字段缺失）——请重新从落地机复制完整的导入命令"
  else
    printf '%s' "$decoded" | grep -Eq '^[[:space:]]*\{[[:space:]]*"ip"[[:space:]]*:[[:space:]]*"[^"]+"[[:space:]]*,[[:space:]]*"dom"[[:space:]]*:[[:space:]]*"[^"]+"([[:space:]]*,[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*:[[:space:]]*("[^"]*"|[0-9]+))*[[:space:]]*\}[[:space:]]*$' \
      || die "token 预校验失败（JSON 畸形或 ip/dom 字段缺失）——请重新从落地机复制完整的导入命令"
  fi
  printf '%s' "$decoded"
}

import_token(){
  local raw="$1"
  [[ -n "$raw" ]] || die "需要 token 参数"
  raw=$(printf '%s' "$raw" | tr -d ' \n\r\t')
  local json=""
  json=$(extract_import_token_json_no_deps "$raw")
  check_deps

  json=$(printf '%s' "$json" | python3 -c "
import json
import sys
decoded = sys.stdin.read()
json.loads(decoded)
print(decoded)
" 2>/dev/null) || die "无法解析 Base64 token，请检查输入"

  local ip="" dom="" port="" uuid="" pwd="" pfx=""
  ip=$(python3  -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['ip'])"  <<< "$json" 2>/dev/null) \
    || die "token 解析失败（ip 字段缺失）——请重新从落地机复制完整的导入命令"
  dom=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['dom'])" <<< "$json" 2>/dev/null) \
    || die "token 解析失败（dom 字段缺失）"
  port=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('port',443))" <<< "$json" 2>/dev/null) || port=443
  [[ "$port" =~ ^[0-9]+$ ]] || port=443
  validate_port "$port"

  # Transit Bug 37 / Token import validation: ip 必须是合法 IPv4，否则给出明确指引
  if ! printf '%s' "$ip" | python3 -c "import ipaddress, sys; ipaddress.IPv4Address(sys.stdin.read().strip())" 2>/dev/null; then
    die "token 中 ip='${ip}' 不是合法 IPv4 地址！\n  可能原因：落地机生成 Token 时 ip/dom 参数位移或旧版 Token 格式不兼容\n  修复方法：在落地机重新运行最新版 install_landing.sh，显示配对信息后复制新的 Base64 Token"
  fi

  # ARCH-2: 解析新版 Token 中的 uuid/pwd/pfx（旧版 Token 不含这些字段，给出友好告警）
  uuid=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('uuid',''))"  <<< "$json" 2>/dev/null) || uuid=""
  pwd=$(python3  -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('pwd',''))"   <<< "$json" 2>/dev/null) || pwd=""
  pfx=$(python3  -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('pfx',''))"   <<< "$json" 2>/dev/null) || pfx=""
  if [[ -z "$uuid" || -z "$pwd" || -z "$pfx" ]]; then
    if [[ "${ALLOW_LEGACY_ROUTE_ONLY:-no}" != "yes" ]]; then
      die "Token 缺少 uuid/pwd/pfx，拒绝导入旧版半功能路由。请在落地机菜单 6 复制新版 Base64 Token 后重试；如只想导入路由，显式设置 ALLOW_LEGACY_ROUTE_ONLY=yes。"
    fi
    warn "ALLOW_LEGACY_ROUTE_ONLY=yes 已启用：只导入路由，不生成订阅节点"
  fi
  # [R-24 FIX] Validate UUID format and password minimum length if present
  if [[ -n "$uuid" && ! "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    die "Token 中 uuid 格式非法（需为标准 UUID 格式）"
  fi
  if [[ -n "$pwd" && ${#pwd} -lt 16 ]]; then
    die "Token 中密码过短（需 ≥16 字符）"
  fi

  validate_ip     "$ip"
  dom=$(trim "$dom" | tr '[:upper:]' '[:lower:]')
  validate_domain "$dom"
  # [R8 Fix] Check for existing domain with different IP before overwrite
  local _existing_node
  # [BUG-4-FIX] 确保目录存在再执行find，避免set -e导致脚本退出
  if [[ -d "$CONF_DIR" ]]; then
    _existing_node=$(find "$CONF_DIR" -name "*.meta" -type f -exec grep -l "^DOMAIN=${dom}$" {} + 2>/dev/null | head -1)
  else
    _existing_node=""
  fi
  if [[ -n "$_existing_node" ]]; then
    local _existing_ip
    _existing_ip=$(read_meta_ip "$_existing_node" 2>/dev/null)
    if [[ "$_existing_ip" != "$ip" ]]; then
      die "域名 ${dom} 已存在于节点文件 ${_existing_node}（中转IP: ${_existing_ip}），不能用不同的中转IP重复导入"
    fi
    warn "域名 ${dom} 已存在，将更新现有配置"
  fi
  # v2.32 Grok: 硬截断防超长域名绕过 map 语法校验
  dom="${dom:0:253}"
  # 🔴 Grok: nginx_domain_str 过滤后若为空（含纯控制字符域名），拒绝生成 map
  local _safe_check; _safe_check=$(nginx_domain_str "$dom")
  [[ -n "$_safe_check" ]] || die "域名过滤后为空（含非法字符），拒绝写入 map: ${dom}"
  info "导入路由规则: ${dom} → ${ip}:${port}"

  if [[ ! -f "$INSTALLED_FLAG" && "${__TRANSIT_FRESH_INSTALL_TRAP_ACTIVE:-0}" == "0" ]]; then
    info "--import 触发首次安装初始化 ..."
    _assert_no_proxy_core_transit
    if ss -tlnp 2>/dev/null | grep -q ':443 '; then
      die "443 端口已被占用！请先停止冲突服务后再安装（建议先执行 systemctl stop nginx xray* mack-a*）"
    fi

    # [v2.8 GPT-Doc2-🔴] Trap registered BEFORE the first side-effect write (check_deps).
    # v2.7 registered it after the 443 check but before check_deps; if apt-get update failed
    # inside check_deps the trap was not yet live → partial nginx install left 443 occupied
    # and the next run's 443 check blocked re-install until manual purge.
    __TRANSIT_IMPORT_TRAP_ACTIVE=1
    _import_install_rollback(){
      [[ "${__TRANSIT_IMPORT_TRAP_ACTIVE:-0}" == "1" ]] || return 0
      warn "--import 安装中断，执行回滚..."
      systemctl stop nginx 2>/dev/null || true
      rm -f "$TRANSIT_FALLBACK_CONF" 2>/dev/null || true
      systemctl disable --now transit-manager-iptables-restore.service 2>/dev/null || true
      rm -f "/etc/systemd/system/transit-manager-iptables-restore.service" 2>/dev/null || true
      sed -i "\#${STREAM_INCLUDE_MARKER}#d" "$NGINX_MAIN_CONF" 2>/dev/null || true
      sed -i "\#include ${NGINX_STREAM_CONF};#d" "$NGINX_MAIN_CONF" 2>/dev/null || true
      for _tc in "$FW_CHAIN" "${FW_CHAIN}-NEW" "${FW_CHAIN}-OLD"; do
        _delete_input_refs_to_chain "$_tc"
        iptables -w 2 -F "$_tc" 2>/dev/null || true
        iptables -w 2 -X "$_tc" 2>/dev/null || true
      done
      systemctl daemon-reload 2>/dev/null || true
      rm -f "$INSTALLED_FLAG" 2>/dev/null || true
      warn "--import 回滚完成。如需重装请重新运行脚本。"
    }
    trap '_import_install_rollback' ERR INT TERM

    optimize_kernel_network; install_nginx; init_nginx_stream; setup_firewall_transit; setup_health_check_transit
    write_logrotate
    # [F2] nginx enable must be durable — silent failure means decoy dies on next reboot
    systemctl enable nginx || die "nginx enable failed — decoy will not survive reboot"
    systemctl is-enabled --quiet nginx || die "nginx is-enabled check failed"
    # [v2.7 Architect-🟠] Remove raw `nginx` fallback — treat startup failure as fatal.
    systemctl is-active --quiet nginx 2>/dev/null || systemctl start nginx \
      || die "Nginx 启动失败（systemctl start 返回非零，已触发回滚）"
    mkdir -p "$MANAGER_BASE"

    # [F1] INSTALLED_FLAG must be committed AFTER _atomic_apply_route, not before.
  fi

  # ARCH-2: 传入 uuid/pwd/pfx，meta 中持久化；generate_nodes() 读取后生成完整订阅
  local _transit_public_ip
  _transit_public_ip=$(get_public_ip --strict)
  _atomic_apply_route "$dom" "$ip" "$port" "$uuid" "$pwd" "$pfx"
  # Commit install marker only after route is durably applied
  [[ -f "$INSTALLED_FLAG" ]] || touch "$INSTALLED_FLAG"
  __TRANSIT_IMPORT_TRAP_ACTIVE=0
  trap '_global_cleanup; echo -e "\n${RED}[中断] 请执行: bash $0 --uninstall${NC}"; exit 1' INT TERM ERR
  success "路由规则导入完成: SNI=${dom} → ${ip}:${port}"
  echo ""
  echo -e "${BOLD}── 导入成功——生成完整节点订阅 ─────────────────────────────────${NC}"
  generate_nodes "$_transit_public_ip"
}

add_landing_route(){
  local env_landing_token="${LANDING_TOKEN:-}"
  local env_landing_ip="${LANDING_IP:-}"
  local env_landing_domain="${LANDING_DOMAIN:-}"
  # 清空全局环境变量，防止后续菜单再次误判为非交互模式；本次调用使用局部快照。
  unset LANDING_IP LANDING_DOMAIN LANDING_PORT LANDING_TOKEN
  
  echo ""
  echo -e "${BOLD}── 增加落地机路由规则 ───────────────────────────────────────────${NC}"
  
  # [BUG-13-FIX] 支持环境变量非交互模式（用于自动化测试）
  if [[ -n "$env_landing_token" ]]; then
    info "检测到 LANDING_TOKEN 环境变量，使用非交互模式"
    _acquire_lock
    import_token "$env_landing_token"
    _release_lock
    # [v5.39 CRITICAL-18] Fix: must return 0 explicitly
    return 0
  elif [[ -n "$env_landing_ip" || -n "$env_landing_domain" ]]; then
    die "非交互模式请使用 LANDING_TOKEN；LANDING_IP/LANDING_DOMAIN 会缺少订阅凭据，已拒绝写入半功能路由"
  fi
  
  # 交互模式：只接受 Token，避免创建缺少订阅凭据的半功能路由。
  echo "  • 请粘贴落地机输出的 Base64 Token 或完整导入命令"
  echo ""
  
  # v2.32: 全局写锁，防两终端并发踩踏状态
  _acquire_lock
  
  # [T1-UX-1-FIX] Token 输入添加重试循环
  local INPUT_DATA=""
  while true; do
    printf "  请粘贴 Token/命令: " >&2
    read -r INPUT_DATA
    INPUT_DATA=$(trim "$INPUT_DATA")
    # 🟠 Grok: 拒绝超长输入，防止畸形字符串绕过 validate 或制造状态分裂
    if (( ${#INPUT_DATA} > 2048 )); then
      error "输入过长（${#INPUT_DATA} 字节），请重新输入"
      continue
    fi
    if [[ -z "$INPUT_DATA" ]]; then
      error "输入不能为空，请重新输入"
      continue
    fi
    local extracted_token=""
    extracted_token=$(printf '%s' "$INPUT_DATA" | python3 -c "
import base64, json, re, sys
raw = sys.stdin.read().strip()
m = re.search(r'(?<![A-Za-z0-9+/=])(?:eyJ|eyA)[A-Za-z0-9+/=]{20,}(?![A-Za-z0-9+/=])', raw)
if not m:
    m = re.search(r'(?<![A-Za-z0-9+/=])[A-Za-z0-9+/=]{40,}(?![A-Za-z0-9+/=])', raw)
if not m:
    raise SystemExit(1)
token = m.group(0)
json.loads(base64.b64decode(token + '=' * (-len(token) % 4)).decode())
print(token)
" 2>/dev/null) || true
    if [[ -n "$extracted_token" ]]; then
      import_token "$INPUT_DATA"; _release_lock; return
    fi
    error "未识别到落地机 Token。请在落地机脚本输出中复制 Base64 Token 或完整导入命令。"
  done
}

delete_landing_route(){
  list_landings
  local meta_count=0
  [[ -d "$CONF_DIR" ]] \
    && meta_count=$(find "$CONF_DIR" -name "*.meta" -type f 2>/dev/null | wc -l) || true
  (( meta_count > 0 )) || { warn "无可删除的落地机"; return; }

  read -rp "请输入要删除的落地机域名（或上方列表中的编号）: " DEL_DOMAIN
  # v2.32: 确认输入后才加锁，避免等待用户输入时持锁过久
  _acquire_lock

  if [[ "$DEL_DOMAIN" =~ ^[0-9]+$ ]]; then
    local n=0 matched=""
    while IFS= read -r meta; do
      (( ++n ))
      if (( n == DEL_DOMAIN )); then
        matched=$(grep '^DOMAIN=' "$meta" 2>/dev/null | awk -F= '{sub(/^[^=]*=/,"",$0); print}') || true; break
      fi
    done < <(find "$CONF_DIR" -name "*.meta" -type f 2>/dev/null | sort)
    [[ -n "$matched" ]] || { _release_lock; die "编号 ${DEL_DOMAIN} 不存在"; }
    DEL_DOMAIN="$matched"
    info "已选择: ${DEL_DOMAIN}"
  else
    DEL_DOMAIN=$(tr '[:upper:]' '[:lower:]' <<< "$DEL_DOMAIN")
  fi

  DEL_DOMAIN=$(trim "$(tr '[:upper:]' '[:lower:]' <<< "$DEL_DOMAIN")")
  validate_domain "$DEL_DOMAIN"
  local safe_del; safe_del=$(domain_to_safe "$DEL_DOMAIN")

  # 五步原子变更：快照 .map + .meta，nginx_reload 失败时恢复
  local _bak_map="" _bak_meta=""
  [[ -f "${SNIPPETS_DIR}/landing_${safe_del}.map" ]] && {
    _bak_map=$(mktemp "${SNIPPETS_DIR}/.snap-recover.XXXXXX") \
      || die "mktemp _bak_map failed"
    cp -f "${SNIPPETS_DIR}/landing_${safe_del}.map" "$_bak_map" \
      || die "snapshot landing map failed"
  }
  [[ -f "${CONF_DIR}/${safe_del}.meta" ]] && {
    _bak_meta=$(mktemp "${CONF_DIR}/.snap-recover.XXXXXX") \
      || die "mktemp _bak_meta failed"
    cp -f "${CONF_DIR}/${safe_del}.meta" "$_bak_meta" \
      || die "snapshot landing meta failed"
  }

  local _delete_route_active=1
  local _prev_delete_err_trap _prev_delete_int_trap _prev_delete_term_trap
  _prev_delete_err_trap=$(trap -p ERR || true)
  _prev_delete_int_trap=$(trap -p INT || true)
  _prev_delete_term_trap=$(trap -p TERM || true)
  _restore_prev_delete_traps(){
    if [[ -n "${_prev_delete_err_trap:-}" ]]; then eval "$_prev_delete_err_trap" || trap - ERR; else trap - ERR; fi
    if [[ -n "${_prev_delete_int_trap:-}" ]]; then eval "$_prev_delete_int_trap" || trap - INT; else trap - INT; fi
    if [[ -n "${_prev_delete_term_trap:-}" ]]; then eval "$_prev_delete_term_trap" || trap - TERM; else trap - TERM; fi
  }
  _delete_route_rollback(){
    [[ "${_delete_route_active:-0}" == "1" ]] || return 0
    _delete_route_active=0
    [[ -n "${_bak_map:-}"  && -f "${_bak_map:-}"  ]] && mv -f "$_bak_map"  "${SNIPPETS_DIR}/landing_${safe_del}.map"  2>/dev/null || true
    [[ -n "${_bak_meta:-}" && -f "${_bak_meta:-}" ]] && mv -f "$_bak_meta" "${CONF_DIR}/${safe_del}.meta"             2>/dev/null || true
    rm -f "${_bak_map:-}" "${_bak_meta:-}" 2>/dev/null || true
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null \
        || warn "删除路由回滚后 Nginx reload/restart 失败，请手动检查"
    else
      warn "删除路由回滚后 Nginx 配置仍无法通过校验，请手动检查"
    fi
    _release_lock
  }
  trap '_delete_route_rollback; _restore_prev_delete_traps; exit 1' INT TERM ERR

  local _delete_ok=1
  if ! remove_landing_snippet "$DEL_DOMAIN"; then
    warn "路由片段删除未完整成功，恢复被删配置..."
    _delete_ok=0
  fi

  if (( _delete_ok == 0 )) || ! ( nginx_reload ); then
    (( _delete_ok == 0 )) || warn "Nginx 热重载失败，恢复被删配置..."
    _delete_route_rollback
    _restore_prev_delete_traps
    die "删除回滚完成，Nginx 运行态未受影响"
  fi
  _delete_route_active=0
  _restore_prev_delete_traps
  rm -f "$_bak_map" "$_bak_meta" 2>/dev/null || true
  _release_lock
  unset -f _delete_route_rollback _restore_prev_delete_traps
  success "落地机路由 ${DEL_DOMAIN} 已删除并热重载生效"
}

show_status(){
  echo ""
  echo -e "${BOLD}── 中转机状态 ──────────────────────────────────────────────────${NC}"
  [[ -f "$INSTALLED_FLAG" ]] && echo "  已安装: 是" || echo "  已安装: 否"
  echo "  Nginx: $(systemctl is-active nginx 2>/dev/null || echo inactive)"
  echo "  监听端口: ${LISTEN_PORT}"
  local snippet_count=0
  [[ -d "$SNIPPETS_DIR" ]] && snippet_count=$(find "$SNIPPETS_DIR" -name "*.map" ! -name "*dummy*" -type f 2>/dev/null | wc -l)
  echo "  已配置落地机: ${snippet_count}"
  list_landings
  echo -e "  ${CYAN}错误日志: tail -f ${LOG_DIR}/transit_stream_error.log${NC}"
  echo ""
  echo -e "  ${BOLD}── 状态硬校验 ────────────────────────────────────────────────${NC}"
  local _ok=1
  systemctl is-active --quiet nginx 2>/dev/null \
    && echo "  Nginx 运行态:    ✓" \
    || { echo -e "  ${RED}Nginx 运行态:    ✗ 未运行${NC}"; _ok=0; }
  ss -tlnp 2>/dev/null | grep -q ":${LISTEN_PORT} " \
    && echo "  :443 监听:       ✓" \
    || { echo -e "  ${RED}:443 监听:       ✗ 端口未开放${NC}"; _ok=0; }
  _fallback_blackhole_ok \
    && echo "  SNI 黑洞服务:    ✓" \
    || { echo -e "  ${RED}SNI 黑洞服务:    ✗ 127.0.0.1:9999 缺失${NC}"; _ok=0; }
  _main_stream_include_valid \
    && echo "  stream include:  ✓" \
    || { echo -e "  ${RED}stream include:  ✗ nginx.conf 中已丢失${NC}"; _ok=0; }
  _stream_conf_valid \
    && echo "  stream 配置:     ✓" \
    || { echo -e "  ${RED}stream 配置:     ✗ 关键指令缺失或漂移${NC}"; _ok=0; }
  nginx -t >/dev/null 2>&1 \
    && echo "  nginx -t:        ✓" \
    || { echo -e "  ${RED}nginx -t:        ✗ 配置校验失败${NC}"; _ok=0; }
  systemctl is-enabled --quiet "transit-manager-iptables-restore.service" 2>/dev/null \
    && echo "  iptables 恢复服务:  ✓ enabled" \
    || { echo -e "  ${RED}iptables 恢复服务:  ✗ 未 enable（重启后规则会丢失）${NC}"; _ok=0; }
  # v2.34 GPT: 恢复脚本与运行链不一致 → _ok=0 直接判红，不允许报"整体一致"
  local _fw_script="${MANAGER_BASE}/firewall-restore.sh"
  if [[ -f "$_fw_script" ]]; then
    # v2.39 GPT #9: 版本签名校验
    local _fw_ver_line; _fw_ver_line=$(grep '^# TRANSIT_FW_VERSION=' "$_fw_script" 2>/dev/null | head -1 || echo "")
    if [[ -z "$_fw_ver_line" ]]; then
      # v2.44 GPT: --status 只读，无签名只报红，不调 _persist_iptables（防巡检引入状态分裂）
      echo -e "  ${RED}恢复脚本版本:    ✗ 无版本签名（旧版/手改脚本）${NC}"; _ok=0
      echo -e "  ${CYAN}  修复: bash $0 --import <token> 重建防火墙持久化脚本${NC}"
    else
      echo -e "  恢复脚本版本:    ${GREEN}✓ ${_fw_ver_line#*=}${NC}"
    fi
    # 校验运行链中 INVALID DROP 规则是否存在
    iptables -w 2 -L "$FW_CHAIN" -n 2>/dev/null | grep -q 'INVALID' \
      && echo -e "  INVALID DROP:    ${GREEN}✓${NC}" \
      || { echo -e "  ${RED}INVALID DROP:    ✗ 规则缺失（执行 --import 或重装以修复）${NC}"; _ok=0; }
    iptables -w 2 -C "$FW_CHAIN" -p udp --dport "$LISTEN_PORT" -m comment --comment "transit-manager-rule" -j DROP 2>/dev/null \
      && echo -e "  UDP 443 DROP:    ${GREEN}✓${NC}" \
      || { echo -e "  ${RED}UDP 443 DROP:    ✗ QUIC 封堵规则缺失（执行 --import 或重装以修复）${NC}"; _ok=0; }
    # proxy_timeout 文件态 vs nginx 运行态对比
    local _rscript_pt _live_pt
    _rscript_pt=$(grep -oE 'proxy_timeout[[:space:]]+[0-9]+' "$NGINX_STREAM_CONF" 2>/dev/null | awk '{print $2}' | head -1 || echo "")
    _live_pt=$(nginx -T 2>/dev/null | grep -oE 'proxy_timeout[[:space:]]+[0-9]+' | awk '{print $2}' | head -1 || echo "")
    if [[ -n "$_rscript_pt" && "$_rscript_pt" != "$_live_pt" ]]; then
      # v2.40 GPT #5: --status 是只读巡检，不执行写操作；漂移只报红，修复用独立命令
      echo -e "  ${RED}恢复脚本存在:    ✗ proxy_timeout 与运行态不一致（需手动修复）${NC}"; _ok=0
      echo -e "  ${CYAN}  修复: bash $0 --import <token> 重建防火墙和持久化脚本${NC}"
    else
      echo -e "  恢复脚本存在:    ${GREEN}✓${NC}"
    fi
  else
    echo -e "  ${RED}恢复脚本:        ✗ 不存在（重启后防火墙规则会丢失）${NC}"; _ok=0
  fi
  # [v5.70 BUG-30] 添加 meta/map 一致性检查（与 main 函数启动检查保持一致）
  if ! _meta_drift_detect 2>/dev/null; then
    echo -e "  ${RED}meta/map 一致性: ✗ .meta 与 .map 不一致${NC}"; _ok=0
    echo -e "  ${CYAN}  修复: bash $0 触发自动修复；仍失败再用 --import <token> 重新导入${NC}"
  else
    echo -e "  meta/map 一致性: ${GREEN}✓${NC}"
  fi
  ((_ok)) \
    && echo -e "  ${GREEN}整体状态: 一致 ✓${NC}" \
    || { echo -e "  ${RED}整体状态: 存在分裂，请排查 ✗${NC}"; echo ""; return 1; }
  echo ""
}

purge_all(){
  echo ""
  warn "此操作清除本脚本所有内容（Nginx 服务不卸载，mack-a 不影响）"
  # [v5.41 CRITICAL-20] Support UNINSTALL_CONFIRM env var for non-interactive uninstall
  if [[ -z "${UNINSTALL_CONFIRM:-}" ]]; then
    read -rp "确认清除？输入 'DELETE' 确认: " CONFIRM
    [[ "$CONFIRM" == "DELETE" ]] || { info "已取消"; return; }
  else
    info "检测到 UNINSTALL_CONFIRM 环境变量，跳过交互确认"
  fi

  # 原子卸载序：先改 nginx.conf → 显式校验 include 已移除 → 再删文件 → 再次 nginx -t → reload
  local _purge_bak=""
  if [[ -f "$NGINX_MAIN_CONF" ]]; then
    _purge_bak=$(mktemp "${MANAGER_BASE}/.snap-recover.XXXXXX") \
      || die "mktemp _purge_bak failed"
    cp -f "$NGINX_MAIN_CONF" "$_purge_bak" \
      || die "snapshot nginx.conf for purge failed"
    sed -i "\#${STREAM_INCLUDE_MARKER}#d" "$NGINX_MAIN_CONF" 2>/dev/null || true
    sed -i "\#include ${NGINX_STREAM_CONF};#d" "$NGINX_MAIN_CONF" 2>/dev/null || true
    sed -i "/# transit-manager-tuning-v${VERSION}/d" "$NGINX_MAIN_CONF" 2>/dev/null || true

    # [v2.10 Grok-Doc7-🔴] Explicitly verify the include marker was removed by sed.
    # A manually-edited nginx.conf (e.g. trailing space on the include line) causes sed to
    # fail silently; without this check the script would delete the stream file and leave
    # nginx.conf referencing a now-missing path → nginx reload failure → host nginx down.
    if grep -q "$STREAM_INCLUDE_MARKER" "$NGINX_MAIN_CONF" 2>/dev/null; then
      [[ -n "$_purge_bak" && -f "$_purge_bak" ]] && mv -f "$_purge_bak" "$NGINX_MAIN_CONF" 2>/dev/null || true
      rm -f "$_purge_bak" 2>/dev/null || true
      die "卸载中止：stream include 标记仍在 nginx.conf（sed 未能匹配）。\n  请手动删除包含 '${STREAM_INCLUDE_MARKER}' 的行，然后重新运行 --uninstall"
    fi
    # Also verify the explicit include path is gone (belt-and-suspenders)
    if grep -qF "include ${NGINX_STREAM_CONF}" "$NGINX_MAIN_CONF" 2>/dev/null; then
      [[ -n "$_purge_bak" && -f "$_purge_bak" ]] && mv -f "$_purge_bak" "$NGINX_MAIN_CONF" 2>/dev/null || true
      rm -f "$_purge_bak" 2>/dev/null || true
      die "卸载中止：include 路径仍在 nginx.conf。请手动清理后重试"
    fi
    # Pre-delete nginx -t: stream file still on disk so we can validate the mutated conf
    if ! nginx -t 2>/dev/null; then
      warn "nginx.conf 校验失败（stream 文件仍存在），还原中..."
      [[ -n "$_purge_bak" && -f "$_purge_bak" ]] && mv -f "$_purge_bak" "$NGINX_MAIN_CONF" 2>/dev/null || true
      rm -f "$_purge_bak" 2>/dev/null || true
      die "卸载中止：nginx.conf 已还原，请手动检查后重试"
    fi
    rm -f "$_purge_bak" 2>/dev/null || true
  fi

  rm -rf "$SNIPPETS_DIR"
  rm -f  "$NGINX_STREAM_CONF" "$TRANSIT_FALLBACK_CONF"

  # [v2.10] Post-delete nginx -t: now that files are gone, confirm nginx.conf is still valid.
  # If this fails the fallback is restart (nginx rebuilds its config from scratch).
  if nginx -t 2>/dev/null; then
    if ! { systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null; }; then
      error "nginx reload 失败！请手动执行: systemctl reload nginx"
      warn "卸载完成，但 nginx 进程未刷新；建议: systemctl restart nginx"
    fi
  else
    warn "nginx -t 失败（配置已删除），尝试直接重启..."
    systemctl restart nginx 2>/dev/null || warn "nginx 重启失败，请手动处理"
  fi

  rm -f "/etc/systemd/system/nginx.service.d/transit-manager-override.conf" 2>/dev/null || true
  rmdir "/etc/systemd/system/nginx.service.d" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  rm -f "${NGINX_MAIN_CONF}.transit.bak_"* 2>/dev/null || true

  # [v2.15.1] purge_all: use bulldozer to remove ALL INPUT references to FW_CHAIN regardless
  # of comment text, then flush and delete. Old comment-based while loops missed rules with
_purge_bulldoze(){
    local _chain="$1" _num _nums
    # [v2.15.2] Delete by line number: re-fetch each pass and delete in descending order
    # so iptables line-number shifts cannot corrupt the rule set.
    while true; do
      _nums=$(iptables -w 2 -L INPUT --line-numbers -n 2>/dev/null               | awk -v c="$_chain" 'NR>2 && $2 == c {print $1}'               | sort -nr)
      [[ -n "${_nums:-}" ]] || break
      while IFS= read -r _num; do
        [[ -n "$_num" ]] || continue
        iptables -w 2 -D INPUT "$_num" 2>/dev/null || break 2
      done <<<"$_nums"
    done
  }
  for _tc in "$FW_CHAIN" "${FW_CHAIN}-NEW" "${FW_CHAIN}-OLD"; do
    _purge_bulldoze "$_tc"
    iptables -w 2 -F "$_tc" 2>/dev/null || true
    iptables -w 2 -X "$_tc" 2>/dev/null || true
  done

  # v2.32 Gemini: IPv6 已彻底删除（v5.25），中转机纯IPv4架构
  systemctl disable --now "transit-manager-iptables-restore.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/transit-manager-iptables-restore.service" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  # 🟠 Grok: 卸载时不写公共持久化文件，避免覆盖宿主机其他防火墙规则
  # iptables-save > /etc/iptables/rules.v4 已移除

  rm -f /etc/sysctl.d/99-transit-bbr.conf /etc/modprobe.d/nf_conntrack.conf 2>/dev/null || true
  # [R9 Fix] Verify sysctl file deletion and reload sysctl to revert settings
  if [[ -f /etc/sysctl.d/99-transit-bbr.conf ]]; then
    warn "无法删除 /etc/sysctl.d/99-transit-bbr.conf（可能是只读文件系统），请手动删除"
  fi
  sysctl --system &>/dev/null || true
  sed -i '/# xray-transit: raised for high-concurrency/,/^root hard nofile/d' /etc/security/limits.conf 2>/dev/null || true
  rm -f /var/run/transit-manager.update.warn 2>/dev/null || true
  rm -f /etc/systemd/journald.conf.d/transit-manager.conf 2>/dev/null || true
  rmdir /etc/systemd/journald.conf.d 2>/dev/null || true
  [[ -z "$(ls -A /etc/systemd/journald.conf.d 2>/dev/null)" ]] && rmdir /etc/systemd/journald.conf.d 2>/dev/null || true
  systemctl restart systemd-journald 2>/dev/null || true
  rm -f "$LOGROTATE_FILE" 2>/dev/null || true
  rm -f /etc/cron.d/transit-health /usr/local/bin/transit-health-check.sh 2>/dev/null || true
  # v2.32 Gemini: 卸载时清除日志目录，防止重装后僵尸日志污染
  rm -rf "$LOG_DIR" 2>/dev/null || true
  rm -rf "$MANAGER_BASE"
  # 卸载后验收
  local _clean=1
  [[ -d "$SNIPPETS_DIR" ]]   && { warn "SNIPPETS_DIR 残留"; _clean=0; } || true
  [[ -f "$NGINX_STREAM_CONF" ]] && { warn "stream conf 残留"; _clean=0; } || true
  systemctl is-active --quiet "transit-manager-iptables-restore.service" 2>/dev/null \
    && { warn "iptables 恢复服务仍活跃"; _clean=0; } || true
  iptables -w 2 -L "$FW_CHAIN" >/dev/null 2>&1 \
    && { warn "iptables chain ${FW_CHAIN} 仍存在"; _clean=0; } || true
  ((_clean)) \
    && success "清除完毕（验收通过），mack-a/v2ray-agent 及 Nginx 均未受影响" \
    || warn "清除完毕，但存在残留项，重装前请手动确认（mack-a 未受影响）"
}

installed_menu(){
  while true; do
    echo ""
    echo -e "${BOLD}${CYAN}══ 中转机管理菜单 ══════════════════════════════════════════════${NC}"
    list_landings
    echo "  1. 增加落地机路由规则（粘贴落地机 Token）"
    echo "  2. 删除指定落地机路由规则"
    echo "  3. 清除本系统所有数据（不影响 mack-a）"
    echo "  4. 退出"
    echo "  5. 显示当前所有节点及订阅链接"
    echo ""
    read -rp "请选择 [1-5]: " CHOICE
    case "$CHOICE" in
      1) add_landing_route ;;
      2) delete_landing_route ;;
      3) purge_all; break ;;
      4) info "退出"; exit 0 ;;
      5) generate_nodes ;;
      *) warn "无效选项: ${CHOICE}" ;;
    esac
  done
}

_fresh_install_rollback(){
  [[ "${__TRANSIT_FRESH_INSTALL_TRAP_ACTIVE:-0}" == "1" ]] || return 0
  warn "安装中断，执行事务回滚..."
  systemctl stop nginx 2>/dev/null || true
  rm -f "$NGINX_STREAM_CONF" 2>/dev/null || true
  rm -f "$TRANSIT_FALLBACK_CONF" 2>/dev/null || true
  rm -f "$LOGROTATE_FILE" 2>/dev/null || true
  rm -f /etc/cron.d/transit-health /usr/local/bin/transit-health-check.sh 2>/dev/null || true
  systemctl disable transit-manager-iptables-restore.service 2>/dev/null || true
  rm -f "/etc/systemd/system/transit-manager-iptables-restore.service" 2>/dev/null || true
  sed -i "\#${STREAM_INCLUDE_MARKER}#d" "$NGINX_MAIN_CONF" 2>/dev/null || true
  sed -i "\#include ${NGINX_STREAM_CONF};#d" "$NGINX_MAIN_CONF" 2>/dev/null || true
  for _tc in "$FW_CHAIN" "${FW_CHAIN}-NEW" "${FW_CHAIN}-OLD"; do
    _delete_input_refs_to_chain "$_tc"
    iptables -w 2 -F "$_tc" 2>/dev/null || true
    iptables -w 2 -X "$_tc" 2>/dev/null || true
  done
  systemctl daemon-reload 2>/dev/null || true
  rm -f "$INSTALLED_FLAG" 2>/dev/null || true
  warn "回滚完成。如需重装请重新运行脚本。"
}

fresh_install(){
  # v2.32 Gemini: 半安装残留检测 — .installed 不存在但 stream include 残留时，
  # 先清除 nginx.conf 中的 include 行，避免后续 443 占用检测误判为"已安装"
  if grep -q "$STREAM_INCLUDE_MARKER" "$NGINX_MAIN_CONF" 2>/dev/null && [[ ! -f "$INSTALLED_FLAG" ]]; then
    warn "检测到半安装残留（stream include 存在但 .installed 缺失），清除 nginx.conf 残留..."
    sed -i "\#${STREAM_INCLUDE_MARKER}#d" "$NGINX_MAIN_CONF" 2>/dev/null || true
    sed -i "\#include ${NGINX_STREAM_CONF};#d" "$NGINX_MAIN_CONF" 2>/dev/null || true
    nginx -t 2>/dev/null && { systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true; } || true
  fi
  echo ""
  echo -e "${BOLD}${CYAN}══ 中转机全新安装 ${VERSION} ══════════════════════════════════════════${NC}"
  echo ""
  echo -e "  本脚本将执行："
  echo -e "  ${GREEN}①${NC} 安装 Nginx（stream 模块，backlog=65535，长连接 600s）"
  echo -e "  ${GREEN}②${NC} 配置 SNI 嗅探纯 TCP 透传（无效/空SNI→本地黑洞，有效SNI→落地机）"
  echo -e "  ${GREEN}③${NC} 优化 TCP conntrack + Nginx fd 上限"
  echo -e "  ${GREEN}④${NC} iptables: 仅开放 SSH + TCP 443 + ICMP，其余 DROP（纯 IPv4）"
  echo -e "  ${GREEN}⑤${NC} 录入第一台落地机配对信息"
  echo ""
  
  # [BUG-13-FIX] 支持环境变量跳过交互确认（用于自动化测试）
  if [[ -n "${LANDING_IP:-}" || -n "${LANDING_DOMAIN:-}" ]]; then
    die "非交互安装请使用 LANDING_TOKEN；LANDING_IP/LANDING_DOMAIN 缺少订阅凭据，拒绝继续"
  fi
  if [[ -n "${LANDING_TOKEN:-}" ]]; then
    extract_import_token_json_no_deps "$LANDING_TOKEN" >/dev/null
  fi
  if [[ -n "${TRANSIT_AUTO_CONFIRM:-}" || -n "${LANDING_TOKEN:-}" ]]; then
    info "检测到自动化环境变量，跳过安装确认"
  else
    read -rp "确认开始安装？[y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "已取消"; exit 0; }
  fi
  _assert_no_proxy_core_transit

  # FW-2 FIX: 半安装死锁：防火墙配置中断后 nginx 仍占用 443，重试时 die 导致无限死锁
  # 判断逻辑：
  #   ① nginx 占 443 + stream include 存在 → 本脚本半装，stop nginx 后继续重装
  #   ② 其他进程占 443 → 真正冲突，die 要求用户手动处理
  if ss -tlnp 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END {exit found ? 0 : 1}' 2>/dev/null; then
    if command -v mack-a &>/dev/null || [[ -f /etc/v2ray-agent/install.sh ]]; then
      warn "检测到 mack-a 已安装，请先停止 mack-a 服务后再安装本脚本"
    fi
    # [v5.18-T-HIGH-2] 增强mack-a检测 - 检查nginx配置冲突
    if [[ -f /etc/nginx/nginx.conf ]] && grep -q "v2ray-agent" /etc/nginx/nginx.conf 2>/dev/null; then
      die "检测到mack-a的nginx配置，请先卸载mack-a"
    fi
    if systemctl is-active --quiet nginx 2>/dev/null \
        && grep -q "$STREAM_INCLUDE_MARKER" "$NGINX_MAIN_CONF" 2>/dev/null; then
      warn "检测到本脚本半安装状态（nginx 占 443 + stream include 存在）"
      warn "自动停止 nginx，清除残留后继续重装..."
      systemctl stop nginx 2>/dev/null || nginx -s stop 2>/dev/null || true
      sleep 1
      # 再次确认 443 已释放
      if ss -tlnp 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END {exit found ? 0 : 1}' 2>/dev/null; then
        die "nginx 停止后 443 仍被占用（可能有其他进程），请手动执行: ss -tlnp | awk '\$4 ~ /:443\$/ {print}'"
      fi
      info "443 端口已释放，继续安装..."
    else
      die "443 端口已被非本脚本进程占用！请先停止冲突服务后再安装（建议先执行 systemctl stop nginx xray* mack-a*）"
    fi
  fi

  __TRANSIT_FRESH_INSTALL_TRAP_ACTIVE=1
  trap '_fresh_install_rollback' ERR INT TERM
  check_deps
  optimize_kernel_network
  install_nginx
  __TRANSIT_FRESH_INSTALL_TRAP_ACTIVE=1
  trap '_fresh_install_rollback' ERR INT TERM
  init_nginx_stream
  __TRANSIT_FRESH_INSTALL_TRAP_ACTIVE=1
  trap '_fresh_install_rollback' ERR INT TERM
  setup_firewall_transit
  __TRANSIT_FRESH_INSTALL_TRAP_ACTIVE=1
  trap '_fresh_install_rollback' ERR INT TERM
  setup_health_check_transit
  __TRANSIT_FRESH_INSTALL_TRAP_ACTIVE=1
  trap '_fresh_install_rollback' ERR INT TERM
  write_logrotate
  __TRANSIT_FRESH_INSTALL_TRAP_ACTIVE=1
  trap '_fresh_install_rollback' ERR INT TERM
  mkdir -p "$MANAGER_BASE"
  # nginx 启动必须在路由导入前完成（路由导入会触发 nginx reload）
  # [F2] hard-fail on enable — reboot persistence is a contract requirement
  __TRANSIT_FRESH_INSTALL_TRAP_ACTIVE=1
  trap '_fresh_install_rollback' ERR INT TERM
  systemctl enable nginx || die "nginx enable failed — decoy will not survive reboot"
  __TRANSIT_FRESH_INSTALL_TRAP_ACTIVE=1
  trap '_fresh_install_rollback' ERR INT TERM
  systemctl is-enabled --quiet nginx || die "nginx is-enabled check failed"
  # [v2.7 Architect-🟠] Remove raw `nginx` fallback: an unmanaged daemon breaks idempotent
  # stop/reload/rollback and leaves the host in a "works now, unmanaged later" state.
  # Startup failure must be fatal and trigger _fresh_install_rollback.
  __TRANSIT_FRESH_INSTALL_TRAP_ACTIVE=1
  trap '_fresh_install_rollback' ERR INT TERM
  systemctl start nginx 2>/dev/null || {
    # Trap is still active, will fire on exit
    die "Nginx 启动失败（systemctl start nginx 返回非零，回滚将自动执行）"
  }

  echo ""
  echo -e "${BOLD}── 录入第一台落地机配对信息 ─────────────────────────────────────${NC}"
  __TRANSIT_FRESH_INSTALL_TRAP_ACTIVE=1
  trap '_fresh_install_rollback' ERR INT TERM
  add_landing_route

  # 路由导入成功，提交安装标记并解除回滚 trap
  __TRANSIT_FRESH_INSTALL_TRAP_ACTIVE=0
  trap '_global_cleanup; echo -e "\n${RED}[中断] 请执行: bash $0 --uninstall${NC}"; exit 1' INT TERM
  # [v5.45 CRITICAL-22] Remove redundant trap reset that causes exit code 1
  # 第2379-2380行的trap重置是多余的，会导致后续命令失败时触发回滚
  touch "$INSTALLED_FLAG"

  echo ""
  success "══ 中转机安装完成！══"
  echo ""
  echo -e "  ${BOLD}错误日志：${NC}"
  # FIX-F: 原路径写死 /var/log/nginx/...，实际路径是 ${LOG_DIR}/...
  echo -e "  ${CYAN}tail -f ${LOG_DIR}/transit_stream_error.log${NC}"
  echo ""
  # [v5.39 CRITICAL-18] Fix: fresh_install must return 0 explicitly
  return 0
}

_ver_gt(){ [[ "$(printf '%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]; }
_check_update(){
  local self_name; self_name=$(basename "${BASH_SOURCE[0]:-$0}")
  local cur_ver="$VERSION"
  local remote
  remote=$(curl -fsSL --connect-timeout 5 --max-time 10 --retry 2 \
    "https://raw.githubusercontent.com/vpn3288/CP-YouHua/main/${self_name}" \
    2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+' | head -1) || return 0
  [[ -n "$remote" ]] && _ver_gt "$remote" "$cur_ver" && warn "发现新版本 ${remote}！建议重新下载" || true
}

main(){
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════════════════════════╗"
  printf "║     美西 CN2 GIA 中转机安装脚本  %-32s║\n" "${VERSION}"
  echo "║     SNI嗅探 → 纯TCP盲传(backlog=65535, proxy_timeout=600s) → 落地机║"
  echo "║     无效/空SNI→本地黑洞 · UDP 443 DROP · 纯 IPv4                 ║"
  echo "║     atomic_write · python validate · logrotate                  ║"
  echo "║     与 mack-a/v2ray-agent 完全物理隔离                         ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then show_help; exit 0; fi
  [[ $EUID -eq 0 ]] || die "必须以 root 身份运行"
  if [[ "${1:-}" == "--uninstall" ]]; then purge_all; exit 0; fi
  if [[ "${1:-}" == "--import" ]]; then
    # v2.32: --import 直接调用时加锁；通过 add_landing_route 间接调用时锁已由调用方持有
    extract_import_token_json_no_deps "${2:-}" >/dev/null
    _acquire_lock; import_token "${2:-}"; _release_lock; exit 0
  fi
  if [[ "${1:-}" == "--status" ]]; then show_status; exit $?; fi

  # [v5.44 CRITICAL-21] Support FORCE_REINSTALL for non-interactive automation
  if [[ "${FORCE_REINSTALL:-no}" == "yes" && -f "$INSTALLED_FLAG" ]]; then
    warn "[FORCE_REINSTALL] 删除安装标记，强制重新安装..."
    rm -f "$INSTALLED_FLAG"
  fi

  mkdir -p "${MANAGER_BASE}/tmp" 2>/dev/null || true
  _check_update >"$UPDATE_WARN_FILE" 2>&1 &
  UPDATE_CHECK_PID=$!
  if [[ ! -f "$INSTALLED_FLAG" ]]; then
    local _durable_transit=0
    local _durable_transit_blocked=0
    local _has_meta_without_flag=0 _has_include_without_flag=0
    find "$CONF_DIR" -maxdepth 1 -type f -name "*.meta" 2>/dev/null | grep -q . && _has_meta_without_flag=1
    _main_stream_include_valid && _has_include_without_flag=1
    if (( _has_meta_without_flag )); then
      if (( _has_include_without_flag == 0 )) || ! _meta_drift_detect; then
        warn "[reconcile] durable set has meta but install flag/include/map may be incomplete — attempting repair before reinstall"
        _acquire_lock
        _repair_maps_from_meta 2>/dev/null || true
        if (( _has_include_without_flag == 0 )); then
          init_nginx_stream 2>/dev/null || true
        fi
        if _meta_drift_detect 2>/dev/null && init_nginx_stream 2>/dev/null && nginx_reload 2>/dev/null; then
          _durable_transit=1
        else
          _durable_transit_blocked=1
        fi
        _release_lock
      else
        _durable_transit=1
      fi
    fi
    if (( _durable_transit_blocked )); then
      error "[reconcile] stream include 与 .meta 存在但 meta/map 仍不一致，拒绝进入全新安装以避免覆盖现有记录"
      echo -e "  请先执行: ${CYAN}bash $0 --status${NC} 排查"
      echo -e "  若确认需要重导，请执行: ${CYAN}bash $0 --import <token>${NC}"
      exit 1
    fi
    if (( _durable_transit )); then
      warn "[reconcile] durable set intact but .installed missing — restoring flag"
      touch "$INSTALLED_FLAG"
    fi
  fi
  if [[ -f "$INSTALLED_FLAG" ]]; then
    # [v2.8 Architect-🟠] Startup stale-marker reconciliation: verify the durable set
    # (nginx stream include + at least one .meta file). A SIGKILL during import_token's
    # first-time path can write INSTALLED_FLAG while nginx artifacts are incomplete.
    local _durable_transit=1 _has_meta=0
    _main_stream_include_valid                                             || _durable_transit=0
    find "$CONF_DIR" -maxdepth 1 -name "*.meta" -type f 2>/dev/null \
         | grep -q . 2>/dev/null                                           && _has_meta=1
    if (( _has_meta == 0 )); then
      warn "[v2.8] 安装标记存在但 .meta 真相源缺失，清除标记重新安装..."
      rm -f "$INSTALLED_FLAG"
      fresh_install
      return
    fi
    (( _durable_transit == 0 )) && warn "[reconcile] stream include 缺失但 .meta 仍存在，将先尝试自动修复"
    # 🟠 GPT: .installed 降为辅助证据，三态交叉校验（nginx/stream-include/meta文件）
    local _svc_ok=0 _inc_ok=0 _meta_ok=0
    systemctl is-active --quiet nginx 2>/dev/null && _svc_ok=1 \
      || warn "Nginx 未运行"
    _main_stream_include_valid && _inc_ok=1 \
      || warn "stream include 已丢失"
    local _mc; _mc=$(find "$CONF_DIR" -name "*.meta" -type f 2>/dev/null | wc -l)
    (( _mc > 0 )) && _meta_ok=1
    # v2.42 GPT #1: 逐项校验 meta→map 对应关系，不只计数
    if ! _meta_drift_detect; then
      warn "真相源不完整: .meta 与 .map 不一致（路由缺失或孤儿文件）"; _meta_ok=0
      local _repaired_routes=0
      _acquire_lock
      _repair_maps_from_meta 2>/dev/null && _repaired_routes=1
      _release_lock
      if (( _repaired_routes )); then
        if _meta_drift_detect 2>/dev/null; then
          success "缺失/漂移 .map 已根据 .meta 修复，真相源已恢复一致"
          _meta_ok=1
        else
          warn "已尝试从 .meta 修复 .map，但仍存在孤儿 .map 或损坏 .meta；为避免误删记录文件，未自动清理"
        fi
      fi
    fi
    # 三态全缺 → 脏安装，清标记重装
    if (( _svc_ok == 0 && _inc_ok == 0 && _meta_ok == 0 )); then
      warn "安装标记存在但三态（nginx/stream/meta）全部缺失，清除标记重新安装..."
      rm -f "$INSTALLED_FLAG"
      fresh_install
      return
    fi
    (( _svc_ok == 0 || _inc_ok == 0 )) && warn "建议先执行 --status 排查状态分裂" || true
    # v2.33 GPT: 部分损坏时先强制 reconcile，失败则拒绝进管理菜单
    local _reconcile_ok=1
    if (( _inc_ok == 0 )); then
      warn "stream include 丢失，自动修复中..."
      # v2.42 GPT #2: reload 成功才算修复，不能只靠 nginx -t
      if init_nginx_stream 2>/dev/null; then
        if systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null; then
          nginx -t 2>/dev/null && success "stream include 已修复（reload 已生效）"             || { warn "stream include 修复后 nginx -t 失败"; _reconcile_ok=0; }
        else
          warn "stream include 修复后 nginx reload 失败（运行态未生效）"; _reconcile_ok=0
        fi
      else
        warn "stream include 修复失败"; _reconcile_ok=0
      fi
    fi
    if (( _inc_ok == 1 )) && ! _stream_conf_valid; then
      warn "stream 配置漂移，自动重写中..."
      if init_nginx_stream 2>/dev/null && nginx_reload 2>/dev/null; then
        success "stream 配置已重写并生效"
      else
        warn "stream 配置重写失败"; _reconcile_ok=0
      fi
    fi
    if (( _svc_ok == 0 )); then
      warn "Nginx 未运行，尝试启动..."
      if systemctl start nginx 2>/dev/null; then
        success "Nginx 已恢复运行"
      else
        warn "Nginx 启动失败"; _reconcile_ok=0
      fi
    fi
    if ! _meta_drift_detect; then
      warn "路由真相源不完整（.meta/.map 不一致），请先执行 --status 排查；若确认需要重导再重新 --import"
      _reconcile_ok=0
    fi
    if (( _reconcile_ok == 0 )); then
      error "自动恢复失败，拒绝进入管理菜单（防止在分裂状态上继续写操作）"
      echo -e "  请先执行: ${CYAN}bash $0 --status${NC} 排查"
      echo -e "  若无法修复，请执行: ${CYAN}bash $0 --uninstall${NC} 清除后重装"
      exit 1
    fi
    installed_menu
  else
    fresh_install
  fi
  # [v5.40 CRITICAL-19] Fix: main must return 0 explicitly after fresh_install
  return 0
}

main "$@"
