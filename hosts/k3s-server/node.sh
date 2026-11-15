#!/usr/bin/env bash
# k3s server 主机配置的安装 / 核对 / 回滚（aster-api ADR 0057 §5 / §6；手册 docs/runbooks/k3s-server-host-config.md）。
#
# 在 control-plane 节点上以 root 运行（用户经 ssh 执行，本仓库不远程操作节点）：
#   node.sh check                       只读：firewalld trusted 区 masquerade、组件文件与仓库是否一致、config.yaml 冲突键
#   node.sh status                      只读：etcd 成员 / leader、kubernetes 端点、已装组件、审计日志占用
#   node.sh preflight <组件>            只读：check + 3 端点 + etcd 3 成员健康 + control-plane 全 Ready + 磁盘 / GitHub 可达
#   node.sh apply <组件> [--no-restart] [--no-auto-rollback]
#                                       preflight → 备份 → 安装 → 重启 k3s → 等就绪 → verify；失败自动回滚
#   node.sh verify <组件>               本次 k3s 启动的日志里参数已生效、审计日志在写 / OIDC 发行方初始化无错
#   node.sh rollback <组件>             删除组件文件（有备份则恢复）→ 重启 → 等就绪
# <组件> 为逗号列表：audit、oidc。退出码：0 成功；1 核对失败或 apply 失败且已回滚；2 用法错误；4 回滚也失败（人工处理）。
#
# ★不读取、不打印 /etc/rancher/k3s/config.yaml 的任何值（含 server token），只按键名计数。
# ★一次只在一台节点上运行；滚动顺序与节点间核对见手册。
# 测试注入：NODE_ROOT、NODE_BUNDLE、SYSTEMCTL、FIREWALL_CMD、JOURNALCTL、CURL、K3S_KUBECTL、DF、NODE_NAME、
#           NODE_WAIT_TIMEOUT（秒，缺省 300）、NODE_POLL（秒，缺省 5）、NODE_AUDIT_WAIT（等首条审计事件，秒，缺省 30）；见 node.test.sh。
# shellcheck disable=SC2015  # ok 恒成功，A && ok || bad 即 if-else
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="${NODE_BUNDLE:-$HERE}/files"
R="${NODE_ROOT:-}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
FIREWALL_CMD="${FIREWALL_CMD:-firewall-cmd}"
JOURNALCTL="${JOURNALCTL:-journalctl}"
CURL="${CURL:-curl}"
DF="${DF:-df}"
read -r -a KUBECTL <<<"${K3S_KUBECTL:-k3s kubectl}"
NODE_NAME="${NODE_NAME:-$(hostname -s)}"
WAIT_TIMEOUT="${NODE_WAIT_TIMEOUT:-300}"
POLL="${NODE_POLL:-5}"
AUDIT_WAIT="${NODE_AUDIT_WAIT:-30}"
ETCD_TLS="$R/var/lib/rancher/k3s/server/tls/etcd"
AUDIT_LOG_DIR="$R/var/lib/rancher/k3s/server/logs"
BACKUP_ROOT="$R/var/lib/rancher/aster-host-backup"
GH_ISSUER=https://token.actions.githubusercontent.com
MIN_FREE_KB=$((2 * 1024 * 1024))
CONTROL_PLANES=3
ALL_COMPONENTS=(audit oidc)
FAILED=0

ok() { echo "ok    $*"; }
warn() { echo "warn  $*"; }
bad() { echo "fail  $*"; FAILED=1; }
usage() { sed -n '3,13p' "$0" >&2; exit 2; }

# 组件 → 相对节点根的文件（drop-in 在前）与 apiserver 参数
component_files() {
  case "$1" in
    audit) echo "etc/rancher/k3s/config.yaml.d/50-aster-audit.yaml etc/rancher/k3s/aster/audit-policy.yaml" ;;
    oidc) echo "etc/rancher/k3s/config.yaml.d/60-aster-oidc.yaml etc/rancher/k3s/aster/authentication-config.yaml" ;;
  esac
}
component_flag() {
  case "$1" in
    audit) echo "--audit-policy-file=/etc/rancher/k3s/aster/audit-policy.yaml" ;;
    oidc) echo "--authentication-config=/etc/rancher/k3s/aster/authentication-config.yaml" ;;
  esac
}
parse_components() {
  [[ -n "${1:-}" ]] || usage
  local c out=()
  IFS=, read -r -a out <<<"$1"
  for c in "${out[@]}"; do [[ "$c" == audit || "$c" == oidc ]] || usage; done
  COMPONENTS=("${out[@]}")
}

sha() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
# component_state <c> → installed | absent | drift
component_state() {
  local f present=0 same=0 total=0
  for f in $(component_files "$1"); do
    total=$((total + 1))
    [[ -f "$R/$f" ]] || continue
    present=$((present + 1))
    [[ "$(sha "$R/$f")" == "$(sha "$BUNDLE/$f")" ]] && same=$((same + 1))
  done
  if ((present == 0)); then echo absent; elif ((same == total)); then echo installed; else echo drift; fi
}

# firewalld：trusted 区不得开 masquerade（#466：跨节点 Pod 流量被伪装后 kube-router 的命名空间 ipset 匹配不上，
# 被放行的跨节点路径被丢弃）。运行时与永久配置都查——只改运行时，下次重载 firewalld 就会复发。
# masq_state <firewall-cmd 参数…> → yes | no | error。firewall-cmd --query-* 约定：0 = 开启、1 = 未开启，
# 其它退出码（firewalld 未响应、区不存在等）是「查不到」——不得当成「没开」放行。
masq_state() {
  local code=0
  "$FIREWALL_CMD" "$@" --query-masquerade >/dev/null 2>&1 || code=$?
  case "$code" in 0) echo yes ;; 1) echo no ;; *) echo error ;; esac
}

# firewalld：trusted 区不得开 masquerade（#466：跨节点 Pod 流量被伪装后 kube-router 的命名空间 ipset 匹配不上，
# 被放行的跨节点路径被丢弃）。运行时与永久配置都查——只改运行时，下次重载 firewalld 就会复发。
check_firewall() {
  if ! "$SYSTEMCTL" is-active --quiet firewalld; then ok "firewalld 未运行（无 masquerade 风险）"; return; fi
  case "$(masq_state --zone=trusted)" in
    no) ok "firewalld trusted 区运行时无 masquerade" ;;
    yes) bad "firewalld trusted 区运行时开着 masquerade（#466）：firewall-cmd --zone=trusted --remove-masquerade" ;;
    *) bad "firewalld trusted 区运行时 masquerade 查询失败（firewall-cmd 非 0/1 退出）：先确认 firewalld 正常" ;;
  esac
  case "$(masq_state --permanent --zone=trusted)" in
    no) ok "firewalld trusted 区永久配置无 masquerade" ;;
    yes) bad "firewalld trusted 区永久配置（permanent）开着 masquerade（#466）：firewall-cmd --permanent --zone=trusted --remove-masquerade" ;;
    *) bad "firewalld trusted 区永久配置 masquerade 查询失败（firewall-cmd 非 0/1 退出）：先确认 firewalld 正常" ;;
  esac
  local z zones
  if ! zones="$("$FIREWALL_CMD" --get-active-zones 2>/dev/null)"; then
    bad "firewall-cmd --get-active-zones 查询失败：无法核对其它区"
    return
  fi
  while read -r z; do
    [[ -n "$z" && "$z" != trusted ]] || continue
    case "$(masq_state --zone="$z")" in
      yes) warn "firewalld $z 区开着 masquerade：确认它不承载 Pod 流量（cni0 / flannel.1 不在该区）" ;;
      error) warn "firewalld $z 区 masquerade 查询失败" ;;
    esac
  done < <(grep -v '^[[:space:]]' <<<"$zones" || true)
}

# config.yaml 与非本组件 drop-in 中不得出现审计 / 认证相关键（与 --authentication-config 冲突或与本组件重复）。
# 只输出文件名与计数，不输出任何值。
check_conflicts() {
  local f n own
  own=" $(component_files audit) $(component_files oidc) "
  for f in "$R/etc/rancher/k3s/config.yaml" "$R"/etc/rancher/k3s/config.yaml.d/*.yaml; do
    [[ -f "$f" ]] || continue
    [[ "$own" == *" ${f#"$R"/} "* ]] && continue
    n="$(grep -cE '(audit-(policy|log|webhook)|oidc-|authentication-config)' "$f" || true)"
    if [[ "$n" != 0 ]]; then bad "${f#"$R"} 含 ${n} 处审计 / 认证相关键（与 hosts/k3s-server 冲突，先人工移除；不要整份贴出该文件）"
    else ok "${f#"$R"} 无冲突键"; fi
  done
}

# do_check [容忍漂移的组件...]：apply 时要覆盖的组件允许处于 drift（那正是升级）
do_check() {
  local c state tolerate=" $* "
  if [[ -f "$R/etc/systemd/system/k3s.service" ]]; then ok "本机是 k3s server（k3s.service）"
  else bad "没有 /etc/systemd/system/k3s.service：本脚本只用于 control-plane（worker-1 是 agent）"; fi
  check_firewall
  for c in "${ALL_COMPONENTS[@]}"; do
    state="$(component_state "$c")"
    case "$state" in
      installed|absent) ok "$state  组件 $c" ;;
      drift) if [[ "$tolerate" == *" $c "* ]]; then warn "drift  组件 ${c}（将被本次 apply 覆盖）"
             else bad "drift  组件 ${c}：与仓库 hosts/k3s-server/files 不一致（手改？），重新 apply 或 rollback"; fi ;;
    esac
  done
  check_conflicts
}

kc() { "${KUBECTL[@]}" "$@"; }
endpoints_count() { kc get endpoints kubernetes -n default -o 'jsonpath={.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' '; }
readyz_ok() { [[ "$(kc get --raw=/readyz 2>/dev/null)" == ok ]]; }
node_ready() { [[ "$(kc get node "$NODE_NAME" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]]; }
cp_ready_count() {
  kc get nodes -l node-role.kubernetes.io/control-plane=true -o 'jsonpath={.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null |
    tr ' ' '\n' | grep -c '^True$' || true
}
etcd() { # etcd <path> [GET]：经本机 etcd 的 grpc-gateway，用 k3s 的 etcd 客户端证书
  local method=(-X POST -d '{}')
  [[ "${2:-}" == GET ]] && method=()
  "$CURL" -fsS --max-time 5 --cacert "$ETCD_TLS/server-ca.crt" --cert "$ETCD_TLS/client.crt" --key "$ETCD_TLS/client.key" \
    "${method[@]}" "https://127.0.0.1:2379$1"
}
# etcd_summary → 一行：members=<n> started=<m> leader=<名字或 ?> local_leader=<yes|no>
etcd_summary() {
  local members status
  members="$(etcd /v3/cluster/member/list 2>/dev/null)" || { echo "members=? started=? leader=? local_leader=?"; return; }
  status="$(etcd /v3/maintenance/status 2>/dev/null || echo '{}')"
  python3 -c '
import json, sys
m = json.loads(sys.argv[1]); s = json.loads(sys.argv[2] or "{}")
ms = m.get("members", [])
started = [x for x in ms if x.get("name") and x.get("clientURLs")]
leader = s.get("leader"); me = s.get("header", {}).get("member_id")
name = next((x.get("name") for x in ms if x.get("ID") == leader), "?")
print("members=%d started=%d leader=%s local_leader=%s" % (len(ms), len(started), name, "yes" if leader and leader == me else "no"))
' "$members" "$status"
}
etcd_local_healthy() { [[ "$(etcd /health GET 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("health"))' 2>/dev/null)" == true ]]; }

do_preflight() {
  do_check "${COMPONENTS[@]}"
  local n s c avail
  n="$(endpoints_count)"
  [[ "$n" == "$CONTROL_PLANES" ]] && ok "kubernetes 端点 ${n} 个" || bad "kubernetes 端点 ${n} 个（须 ${CONTROL_PLANES}）：先排查别的 apiserver，不要在仲裁边缘重启"
  # 节点名先核对：等就绪时按它判断本节点 Ready，名字不对会把成功的重启误判为失败并回滚。
  node_ready && ok "本节点 ${NODE_NAME} Ready" || bad "节点 ${NODE_NAME} 不存在或未 Ready（hostname 与 k8s 节点名不同时设 NODE_NAME=<节点名>）"
  n="$(cp_ready_count)"
  [[ "$n" == "$CONTROL_PLANES" ]] && ok "control-plane Ready ${n} 台" || bad "control-plane Ready ${n} 台（须 ${CONTROL_PLANES}）"
  s="$(etcd_summary)"
  [[ "$s" == "members=$CONTROL_PLANES started=$CONTROL_PLANES "* ]] && ok "etcd $s" || bad "etcd 成员不全或未启动：$s"
  etcd_local_healthy && ok "本机 etcd /health = true" || bad "本机 etcd /health 不是 true"
  for c in "${COMPONENTS[@]}"; do
    case "$c" in
      audit)
        avail="$("$DF" -Pk "$R/var/lib/rancher" 2>/dev/null | awk 'NR == 2 {print $4}')"
        if [[ "$avail" =~ ^[0-9]+$ ]] && ((avail >= MIN_FREE_KB)); then ok "/var/lib/rancher 可用 $((avail / 1024 / 1024)) GiB"
        else bad "/var/lib/rancher 可用空间不足 2 GiB（${avail:-?} KiB）：审计日志上限约 0.5 GB，先清理"; fi ;;
      oidc)
        local disc issuer jwks
        disc="$("$CURL" -fsS --max-time 10 "$GH_ISSUER/.well-known/openid-configuration" 2>/dev/null || true)"
        issuer="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("issuer",""))' "${disc:-{\}}" 2>/dev/null || true)"
        jwks="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("jwks_uri",""))' "${disc:-{\}}" 2>/dev/null || true)"
        if [[ "$issuer" == "$GH_ISSUER" ]] && [[ -n "$jwks" ]] && "$CURL" -fsS --max-time 10 "$jwks" >/dev/null 2>&1; then
          ok "GitHub OIDC 发现文档与 JWKS 可达（issuer 一致）"
        else bad "本机访问不到 GitHub OIDC 发现文档 / JWKS，或 issuer 不符（${issuer:-无}）：查出站（OCI 路由 / 安全列表 / firewalld）"; fi ;;
    esac
  done
}

wait_ready() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  while ((SECONDS < deadline)); do
    if "$SYSTEMCTL" is-active --quiet k3s && readyz_ok && [[ "$(endpoints_count)" == "$CONTROL_PLANES" ]] && node_ready; then
      ok "k3s 就绪：本地 /readyz ok、端点 ${CONTROL_PLANES} 个、${NODE_NAME} Ready"
      return 0
    fi
    sleep "$POLL"
  done
  bad "等待 ${WAIT_TIMEOUT}s 后 k3s 仍未就绪（看 journalctl -u k3s -n 200）"
  return 1
}

do_verify() {
  local c inv journal flag deadline
  "$SYSTEMCTL" is-active --quiet k3s && ok "k3s active" || bad "k3s 不是 active"
  readyz_ok && ok "本地 /readyz ok" || bad "本地 /readyz 不是 ok"
  # 只看本次 k3s 启动（同一个 systemd InvocationID）的日志，避免把上一次启动的参数行当成证据。
  inv="$("$SYSTEMCTL" show -p InvocationID --value k3s 2>/dev/null || true)"
  journal="$("$JOURNALCTL" -u k3s "_SYSTEMD_INVOCATION_ID=$inv" --no-pager -o cat 2>/dev/null || true)"
  for c in "${COMPONENTS[@]}"; do
    flag="$(component_flag "$c")"
    if grep 'Running kube-apiserver' <<<"$journal" | tail -n1 | grep -qF -- "$flag"; then ok "apiserver 参数已生效：$flag"
    else bad "本次启动的 apiserver 参数里没有 ${flag}（drop-in 未被读取？）"; fi
    case "$c" in
      audit)
        deadline=$((SECONDS + AUDIT_WAIT))
        until [[ -s "$AUDIT_LOG_DIR/audit.log" ]] || ((SECONDS >= deadline)); do sleep "$POLL"; done
        if [[ -s "$AUDIT_LOG_DIR/audit.log" ]] && tail -n1 "$AUDIT_LOG_DIR/audit.log" | grep -q '"apiVersion":"audit.k8s.io/v1"'; then
          ok "审计日志在写（最后一行是 audit.k8s.io/v1 Event）"
        else bad "审计日志 $AUDIT_LOG_DIR/audit.log 不存在、为空或最后一行不是审计事件"; fi ;;
      oidc)
        if grep -iE 'oidc authenticator|authentication-config|AuthenticationConfiguration' <<<"$journal" | grep -qiE 'error|fail|invalid|E[0-9]{4} '; then
          bad "本次启动日志中 OIDC 认证器有错误：$(grep -iE 'oidc authenticator' <<<"$journal" | tail -n1 | cut -c1-200)"
        else ok "本次启动日志中无 OIDC 认证器错误"; fi ;;
    esac
  done
}

install_file() { # install_file <相对路径> <备份目录>
  local rel="$1" bk="$2" dst="$R/$1"
  if [[ -f "$dst" ]]; then mkdir -p "$bk/$(dirname "$rel")"; cp -p "$dst" "$bk/$rel"; fi
  mkdir -p "$(dirname "$dst")"
  cp "$BUNDLE/$rel" "$dst.aster-tmp"
  chmod 0600 "$dst.aster-tmp"
  mv -f "$dst.aster-tmp" "$dst"
}

remove_component() { # 删除组件文件；本组件最近一次 apply 的备份存在则恢复
  local c="$1" f bk=""
  [[ -f "$BACKUP_ROOT/last-$c" ]] && bk="$(cat "$BACKUP_ROOT/last-$c")"
  for f in $(component_files "$c"); do
    rm -f "$R/$f"
    if [[ -n "$bk" && -f "$bk/$f" ]]; then cp -p "$bk/$f" "$R/$f"; ok "已恢复备份 /$f"; else ok "已删除 /$f"; fi
  done
}

do_rollback() {
  local c
  for c in "${COMPONENTS[@]}"; do remove_component "$c"; done
  "$SYSTEMCTL" restart k3s || true
  FAILED=0
  wait_ready
}

do_apply() {
  local restart=1 autorb=1 c f bk
  for a in "$@"; do
    case "$a" in
      --no-restart) restart=0 ;;
      --no-auto-rollback) autorb=0 ;;
      *) usage ;;
    esac
  done
  do_preflight
  if [[ "$FAILED" != 0 ]]; then echo "preflight 未通过：未安装任何文件，未重启" >&2; exit 1; fi
  bk="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$bk"
  mkdir -p "$R/etc/rancher/k3s/aster" && chmod 0700 "$R/etc/rancher/k3s/aster"
  for c in "${COMPONENTS[@]}"; do
    for f in $(component_files "$c"); do install_file "$f" "$bk"; ok "已安装 /${f}（0600）"; done
    echo "$bk" >"$BACKUP_ROOT/last-$c"
    if [[ "$c" == audit ]]; then mkdir -p "$AUDIT_LOG_DIR" && chmod 0700 "$AUDIT_LOG_DIR"; fi
  done
  if [[ "$restart" == 0 ]]; then echo "已暂存（--no-restart）：重启 k3s 后执行 node.sh verify ${COMPONENTS[*]// /,}"; exit 0; fi
  echo "重启 k3s（${NODE_NAME}）…"
  "$SYSTEMCTL" restart k3s || bad "systemctl restart k3s 失败"
  if [[ "$FAILED" == 0 ]] && wait_ready && { do_verify; [[ "$FAILED" == 0 ]]; }; then
    echo "apply ${COMPONENTS[*]} 完成：在 Mac 上核对 kubectl get nodes 与 endpoints 后再处理下一台"
    exit 0
  fi
  if [[ "$autorb" == 0 ]]; then echo "apply 失败（--no-auto-rollback，保留现场）：手动 node.sh rollback 或排查" >&2; exit 1; fi
  echo "apply 失败，自动回滚 ${COMPONENTS[*]} …" >&2
  if do_rollback; then echo "已回滚并恢复就绪；排查后再试" >&2; exit 1; fi
  echo "回滚后 k3s 仍未就绪：需要人工处理（journalctl -u k3s -n 200；删除 /etc/rancher/k3s/config.yaml.d/*-aster-*.yaml 后 systemctl restart k3s）" >&2
  exit 4
}

do_status() {
  local c
  echo "节点 ${NODE_NAME}"
  for c in "${ALL_COMPONENTS[@]}"; do echo "组件 ${c}：$(component_state "$c")"; done
  echo "kubernetes 端点：$(endpoints_count) 个；control-plane Ready：$(cp_ready_count) 台"
  local s; s="$(etcd_summary)"
  echo "etcd：$s"
  [[ "$s" == *"local_leader=yes"* ]] && echo "★本节点是 etcd leader：滚动时放在最后"
  if [[ -d "$AUDIT_LOG_DIR" ]]; then echo "审计日志占用：$(du -sh "$AUDIT_LOG_DIR" 2>/dev/null | cut -f1)"; fi
}

cmd="${1:-}"; [[ $# -gt 0 ]] && shift
COMPONENTS=()
case "$cmd" in
  check) [[ $# == 0 ]] || usage; do_check; exit "$FAILED" ;;
  status) [[ $# == 0 ]] || usage; do_status ;;
  preflight) parse_components "${1:-}"; shift; [[ $# == 0 ]] || usage; do_preflight; exit "$FAILED" ;;
  verify) parse_components "${1:-}"; shift; [[ $# == 0 ]] || usage; do_verify; exit "$FAILED" ;;
  apply) parse_components "${1:-}"; shift; do_apply "$@" ;;
  rollback)
    parse_components "${1:-}"; shift; [[ $# == 0 ]] || usage
    if do_rollback; then exit 0; else exit 4; fi ;;
  *) usage ;;
esac
