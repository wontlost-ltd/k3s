#!/usr/bin/env bash
# hosts/k3s-server/node.sh 的离线测试（aster-api ADR 0057 §5 / §6；计划 Task 3）。
#
# 临时目录充当节点根（NODE_ROOT），假 systemctl / firewall-cmd / journalctl / curl / kubectl / df 读环境变量决定行为：
#   - 假 systemctl restart 按根目录里实际安装了哪些 drop-in 生成「Running kube-apiserver …」日志行与审计日志，
#     所以 verify 断言的是「装了什么就生效了什么」，而不是测试预先写好的答案；
#   - FAKE_BREAK_ON=<相对路径>：该文件存在时 apiserver 不就绪（模拟配置错误导致起不来），用于自动回滚用例。
# 用法：bash hosts/k3s-server/node.test.sh；依赖 python3（node.sh 在节点上用它解析 etcd JSON）。
# shellcheck disable=SC2015  # pass 恒成功，A && pass || fail 即 if-else
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE="$HERE/node.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1${2:+：$2}"; FAILED=1; }

BIN="$WORK/bin"; mkdir -p "$BIN"
cat >"$BIN/systemctl" <<'SH'
#!/usr/bin/env bash
echo "systemctl $*" >>"$FAKE_LOG"
case "$*" in
  "is-active --quiet firewalld") [[ "${FAKE_FW_ACTIVE:-1}" == 1 ]] ;;
  "is-active --quiet k3s") [[ "${FAKE_K3S_ACTIVE:-1}" == 1 ]] ;;
  "show -p InvocationID --value k3s") echo inv-1 ;;
  "restart k3s")
    r="$NODE_ROOT"
    flags="--advertise-address=192.168.0.3 --etcd-servers=https://127.0.0.1:2379"
    [[ -f "$r/etc/rancher/k3s/config.yaml.d/50-aster-audit.yaml" ]] && flags+=" --audit-policy-file=/etc/rancher/k3s/aster/audit-policy.yaml --audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log"
    [[ -f "$r/etc/rancher/k3s/config.yaml.d/60-aster-oidc.yaml" ]] && flags+=" --authentication-config=/etc/rancher/k3s/aster/authentication-config.yaml"
    printf 'time="x" level=info msg="Running kube-apiserver %s"\n' "$flags" >"$FAKE_STATE/journal"
    [[ -n "${FAKE_JOURNAL_EXTRA:-}" ]] && printf '%s\n' "$FAKE_JOURNAL_EXTRA" >>"$FAKE_STATE/journal"
    if [[ -f "$r/etc/rancher/k3s/config.yaml.d/50-aster-audit.yaml" && "${FAKE_AUDIT_WRITES:-1}" == 1 && -d "$r/var/lib/rancher/k3s/server/logs" ]]; then
      echo '{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"Metadata"}' >>"$r/var/lib/rancher/k3s/server/logs/audit.log"
    fi
    [[ "${FAKE_RESTART_FAIL:-0}" != 1 ]] ;;
  *) exit 0 ;;
esac
SH
cat >"$BIN/firewall-cmd" <<'SH'
#!/usr/bin/env bash
echo "firewall-cmd $*" >>"$FAKE_LOG"
[[ -n "${FAKE_FW_ERR:-}" && "$*" == "$FAKE_FW_ERR" ]] && { echo "Error: something" >&2; exit 252; }
case "$*" in
  "--get-active-zones") [[ "${FAKE_ZONES_ERR:-0}" == 1 ]] && exit 252; for z in ${FAKE_ZONES:-public trusted}; do echo "$z"; echo "  interfaces: eth0"; done ;;
  "--permanent --zone="*" --query-masquerade") z="${2#--zone=}"; [[ " ${FAKE_MASQ_PERM:-} " == *" $z "* ]] && { echo yes; exit 0; }; echo no; exit 1 ;;
  "--zone="*" --query-masquerade") z="${1#--zone=}"; [[ " ${FAKE_MASQ_RUNTIME:-} " == *" $z "* ]] && { echo yes; exit 0; }; echo no; exit 1 ;;
  *) exit 2 ;;
esac
SH
cat >"$BIN/journalctl" <<'SH'
#!/usr/bin/env bash
echo "journalctl $*" >>"$FAKE_LOG"
cat "$FAKE_STATE/journal" 2>/dev/null || true
SH
cat >"$BIN/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >>"$FAKE_LOG"
url="${*: -1}"
case "$url" in
  */v3/cluster/member/list) cat "$FAKE_MEMBERS" ;;
  */v3/maintenance/status) echo '{"header":{"member_id":"2"},"leader":"'"${FAKE_LEADER:-1}"'"}' ;;
  */health) echo '{"health":"'"${FAKE_ETCD_HEALTH:-true}"'"}' ;;
  https://token.actions.githubusercontent.com/.well-known/openid-configuration)
    [[ "${FAKE_GH_DOWN:-0}" == 1 ]] && exit 7
    echo '{"issuer":"'"${FAKE_GH_ISSUER:-https://token.actions.githubusercontent.com}"'","jwks_uri":"https://token.actions.githubusercontent.com/.well-known/jwks"}' ;;
  https://token.actions.githubusercontent.com/.well-known/jwks) echo '{"keys":[{"kid":"k"}]}' ;;
  *) echo "unexpected curl $url" >&2; exit 99 ;;
esac
SH
cat >"$BIN/kubectl" <<'SH'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_LOG"
broken=0
[[ -n "${FAKE_BREAK_ON:-}" && -e "$NODE_ROOT/$FAKE_BREAK_ON" ]] && broken=1
case "$*" in
  "get --raw=/readyz") [[ "$broken" == 0 && "${FAKE_READYZ:-ok}" == ok ]] && echo ok || { echo "fail" >&2; exit 1; } ;;
  "get endpoints kubernetes -n default"*) [[ "$broken" == 1 ]] && echo "192.168.0.2 192.168.0.4" || echo "${FAKE_ENDPOINTS-192.168.0.2 192.168.0.3 192.168.0.4}" ;;
  "get nodes -l node-role.kubernetes.io/control-plane=true"*) echo "${FAKE_CP_READY-True True True}" ;;
  "get node master-2 "*) echo "${FAKE_NODE_READY:-True}" ;;
  *) echo "unexpected kubectl $*" >&2; exit 99 ;;
esac
SH
cat >"$BIN/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda3 30867456 23000000 %s 75%% /\n' "${FAKE_AVAIL_KB:-6000000}"
SH
chmod +x "$BIN"/*

members() { # members <started 数> <总数>
  python3 - "$1" "$2" >"$WORK/members.json" <<'PY'
import json, sys
started, total = int(sys.argv[1]), int(sys.argv[2])
ms = []
for i in range(total):
    ip = f"192.168.0.{i + 2}"
    if i < started:
        ms.append({"ID": str(i + 1), "name": f"master-{i + 1}-abc", "clientURLs": [f"https://{ip}:2379"], "peerURLs": [f"https://{ip}:2380"]})
    else:
        ms.append({"ID": str(i + 1), "peerURLs": [f"https://{ip}:2380"]})
print(json.dumps({"header": {"member_id": "2"}, "members": ms}))
PY
}

# 每个用例一个新的节点根：干净主机 = 有 k3s.service、config.yaml（含一行假 token）、etcd 证书文件。
fresh() {
  ROOT_DIR="$WORK/root-$RANDOM$RANDOM"
  mkdir -p "$ROOT_DIR/etc/systemd/system" "$ROOT_DIR/etc/rancher/k3s/config.yaml.d" "$ROOT_DIR/var/lib/rancher/k3s/server/tls/etcd"
  : >"$ROOT_DIR/etc/systemd/system/k3s.service"
  printf 'token: SUPERSECRET-TOKEN-VALUE\nnode-taint:\n  - CriticalAddonsOnly=true:NoExecute\n' >"$ROOT_DIR/etc/rancher/k3s/config.yaml"
  STATE="$WORK/state-$RANDOM$RANDOM"; mkdir -p "$STATE"
  : >"$WORK/log"
  members 3 3
}
# run <args...>：以当前假环境运行 node.sh，stdout+stderr → $WORK/out，返回退出码
run() {
  local code=0
  env PATH="$BIN:$PATH" NODE_ROOT="$ROOT_DIR" FAKE_STATE="$STATE" FAKE_LOG="$WORK/log" FAKE_MEMBERS="$WORK/members.json" \
    K3S_KUBECTL="$BIN/kubectl" SYSTEMCTL="$BIN/systemctl" FIREWALL_CMD="$BIN/firewall-cmd" JOURNALCTL="$BIN/journalctl" \
    CURL="$BIN/curl" DF="$BIN/df" NODE_NAME=master-2 NODE_WAIT_TIMEOUT="${NODE_WAIT_TIMEOUT:-2}" NODE_POLL=0.2 NODE_AUDIT_WAIT=1 \
    bash "$NODE" "$@" >"$WORK/out" 2>&1 || code=$?
  echo "$code"
}
installed() { [[ -f "$ROOT_DIR/etc/rancher/k3s/config.yaml.d/$1" ]]; }
restarts() { grep -c '^systemctl restart k3s' "$WORK/log" || true; }

echo "== check"
fresh; c="$(run check)"
[[ "$c" == 0 ]] && grep -q 'absent.*audit' "$WORK/out" && grep -q 'absent.*oidc' "$WORK/out" &&
  pass check_passes_on_clean_host || fail check_passes_on_clean_host "$c $(cat "$WORK/out")"
fresh; c="$(FAKE_MASQ_RUNTIME=trusted run check)"
[[ "$c" == 1 ]] && grep -q 'trusted' "$WORK/out" && pass check_fails_on_trusted_masquerade_runtime || fail check_fails_on_trusted_masquerade_runtime "$c"
fresh; c="$(FAKE_MASQ_PERM=trusted run check)"
[[ "$c" == 1 ]] && grep -qi 'permanent\|永久' "$WORK/out" && pass check_fails_on_trusted_masquerade_permanent || fail check_fails_on_trusted_masquerade_permanent "$c"
fresh; c="$(FAKE_MASQ_RUNTIME=public run check)"
[[ "$c" == 0 ]] && grep -q '^warn.*public' "$WORK/out" && pass check_warns_other_zone_masquerade || fail check_warns_other_zone_masquerade "$c $(cat "$WORK/out")"
fresh; c1="$(FAKE_FW_ERR="--zone=trusted --query-masquerade" run check)"; o1="$(cat "$WORK/out")"
c2="$(FAKE_FW_ERR="--permanent --zone=trusted --query-masquerade" run check)"; c3="$(FAKE_ZONES_ERR=1 run check)"
[[ "$c1 $c2 $c3" == "1 1 1" ]] && grep -q '查询失败' <<<"$o1" &&
  pass "check_fails_when_firewalld_query_errors（非 0/1 退出码 ≠ 无 masquerade）" || fail check_fails_when_firewalld_query_errors "$c1 $c2 $c3"
fresh; c="$(FAKE_FW_ACTIVE=0 FAKE_MASQ_RUNTIME=trusted run check)"
[[ "$c" == 0 ]] && ! grep -q 'firewall-cmd' "$WORK/log" && pass check_skips_firewall_when_inactive || fail check_skips_firewall_when_inactive "$c"
fresh; run apply audit --no-restart >/dev/null; echo "# 手改" >>"$ROOT_DIR/etc/rancher/k3s/aster/audit-policy.yaml"; c="$(run check)"
[[ "$c" == 1 ]] && grep -q 'drift.*audit' "$WORK/out" && pass check_fails_on_drift || fail check_fails_on_drift "$c $(cat "$WORK/out")"
fresh; rm "$ROOT_DIR/etc/rancher/k3s/config.yaml.d/50-aster-audit.yaml" 2>/dev/null || true
run apply audit --no-restart >/dev/null; rm "$ROOT_DIR/etc/rancher/k3s/aster/audit-policy.yaml"; c="$(run check)"
[[ "$c" == 1 ]] && grep -q 'drift.*audit' "$WORK/out" && pass check_fails_on_partial_install || fail check_fails_on_partial_install "$c"
fresh; printf 'kube-apiserver-arg:\n  - oidc-issuer-url=https://x\n' >>"$ROOT_DIR/etc/rancher/k3s/config.yaml"
printf 'kube-apiserver-arg+:\n  - audit-log-path=/tmp/x\n' >"$ROOT_DIR/etc/rancher/k3s/config.yaml.d/10-hand.yaml"; c="$(run check)"
[[ "$c" == 1 ]] && grep -q 'config.yaml' "$WORK/out" && grep -q '10-hand.yaml' "$WORK/out" && ! grep -q 'SUPERSECRET' "$WORK/out" && ! grep -q 'oidc-issuer-url=https' "$WORK/out" &&
  pass "check_fails_on_conflicting_config_keys（只报计数，不回显值 / token）" || fail check_fails_on_conflicting_config_keys "$c $(cat "$WORK/out")"
fresh; rm "$ROOT_DIR/etc/systemd/system/k3s.service"; c="$(run check)"
[[ "$c" == 1 ]] && pass check_fails_on_agent_node || fail check_fails_on_agent_node "$c"

echo "== preflight"
fresh; c="$(FAKE_ENDPOINTS="192.168.0.2 192.168.0.4" run preflight audit)"
[[ "$c" == 1 ]] && pass preflight_fails_when_endpoints_lt_3 || fail preflight_fails_when_endpoints_lt_3 "$c"
fresh; members 2 3; c="$(run preflight audit)"
[[ "$c" == 1 ]] && grep -q 'etcd' "$WORK/out" && pass preflight_fails_when_etcd_member_unstarted || fail preflight_fails_when_etcd_member_unstarted "$c"
fresh; c="$(FAKE_ETCD_HEALTH=false run preflight audit)"
[[ "$c" == 1 ]] && pass preflight_fails_when_local_etcd_unhealthy || fail preflight_fails_when_local_etcd_unhealthy "$c"
fresh; c="$(FAKE_CP_READY="True False True" run preflight audit)"
[[ "$c" == 1 ]] && pass preflight_fails_when_control_plane_not_ready || fail preflight_fails_when_control_plane_not_ready "$c"
fresh; c="$(FAKE_AVAIL_KB=1000000 run preflight audit)"
[[ "$c" == 1 ]] && grep -q 'GiB' "$WORK/out" && pass preflight_fails_low_disk || fail preflight_fails_low_disk "$c"
fresh; c1="$(FAKE_GH_DOWN=1 run preflight oidc)"; c2="$(FAKE_GH_ISSUER=https://evil.example run preflight oidc)"; c3="$(run preflight oidc)"
[[ "$c1 $c2 $c3" == "1 1 0" ]] && pass preflight_oidc_needs_github_discovery || fail preflight_oidc_needs_github_discovery "$c1 $c2 $c3"
fresh; c="$(FAKE_NODE_READY=False run preflight audit)"
[[ "$c" == 1 ]] && grep -q 'NODE_NAME' "$WORK/out" && pass "preflight_fails_when_node_name_unknown（防误判回滚）" || fail preflight_fails_when_node_name_unknown "$c"
fresh; c="$(FAKE_MASQ_PERM=trusted run preflight audit)"
[[ "$c" == 1 ]] && pass preflight_includes_check || fail preflight_includes_check "$c"

echo "== apply / verify / rollback"
fresh; c="$(run apply audit)"
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }  # GNU 优先：GNU stat -f 是文件系统信息，不会失败
if [[ "$c" == 0 ]] && installed 50-aster-audit.yaml && [[ "$(mode_of "$ROOT_DIR/etc/rancher/k3s/aster/audit-policy.yaml")" == 600 &&
  "$(mode_of "$ROOT_DIR/etc/rancher/k3s/config.yaml.d/50-aster-audit.yaml")" == 600 && "$(mode_of "$ROOT_DIR/etc/rancher/k3s/aster")" == 700 &&
  "$(mode_of "$ROOT_DIR/var/lib/rancher/k3s/server/logs")" == 700 && "$(restarts)" == 1 ]] &&
  cmp -s "$HERE/files/etc/rancher/k3s/aster/audit-policy.yaml" "$ROOT_DIR/etc/rancher/k3s/aster/audit-policy.yaml" && ! installed 60-aster-oidc.yaml; then
  pass "apply_installs_files_0600_and_restarts（只装所选组件、目录 0700、重启 1 次）"
else fail apply_installs_files_0600_and_restarts "$c restarts=$(restarts) $(cat "$WORK/out")"; fi
c="$(run check)"; [[ "$c" == 0 ]] && grep -q 'installed.*audit' "$WORK/out" && pass "apply 后 check 报 installed" || fail "apply 后 check" "$c"
fresh; c="$(run apply audit --no-restart)"
[[ "$c" == 0 ]] && installed 50-aster-audit.yaml && [[ "$(restarts)" == 0 ]] && pass apply_no_restart_only_stages || fail apply_no_restart_only_stages "$c"
fresh; c="$(run apply audit,oidc)"
[[ "$c" == 0 ]] && installed 50-aster-audit.yaml && installed 60-aster-oidc.yaml && [[ "$(restarts)" == 1 ]] &&
  pass "apply 两个组件一次重启" || fail "apply audit,oidc" "$c $(cat "$WORK/out")"
fresh; c="$(FAKE_BREAK_ON=etc/rancher/k3s/config.yaml.d/60-aster-oidc.yaml run apply oidc)"
[[ "$c" == 1 ]] && ! installed 60-aster-oidc.yaml && [[ ! -e "$ROOT_DIR/etc/rancher/k3s/aster/authentication-config.yaml" && "$(restarts)" == 2 ]] && grep -q '回滚' "$WORK/out" &&
  pass "apply_rolls_back_when_not_ready（删除文件、再重启一次）" || fail apply_rolls_back_when_not_ready "$c restarts=$(restarts) $(cat "$WORK/out")"
fresh; c="$(FAKE_AUDIT_WRITES=0 run apply audit)"
[[ "$c" == 1 ]] && ! installed 50-aster-audit.yaml && [[ "$(restarts)" == 2 ]] && pass "apply_rolls_back_when_verify_fails（审计日志未产生）" || fail apply_rolls_back_when_verify_fails "$c $(cat "$WORK/out")"
fresh; c="$(FAKE_BREAK_ON=etc/rancher/k3s/config.yaml.d/60-aster-oidc.yaml run apply oidc --no-auto-rollback)"
[[ "$c" == 1 ]] && installed 60-aster-oidc.yaml && [[ "$(restarts)" == 1 ]] && pass "--no-auto-rollback 失败时保留现场" || fail "--no-auto-rollback" "$c"
fresh; c="$(FAKE_BREAK_ON=etc/rancher/k3s/aster FAKE_BREAK2=1 run apply oidc)"
# etc/rancher/k3s/aster 目录在回滚后仍存在（审计组件未装时也可能残留空目录）→ 回滚后依旧不就绪 → 4
[[ "$c" == 4 ]] && grep -q '人工' "$WORK/out" && pass "apply 回滚也失败时退出 4 并提示人工处理" || fail "rollback failure exit 4" "$c $(cat "$WORK/out")"
fresh; c="$(FAKE_ENDPOINTS="192.168.0.2" run apply audit)"
[[ "$c" == 1 ]] && ! installed 50-aster-audit.yaml && [[ "$(restarts)" == 0 ]] && pass "apply_refuses_on_preflight_failure（不装文件、不重启）" || fail apply_refuses_on_preflight_failure "$c"
fresh; printf 'kube-apiserver-arg+:\n  - audit-log-maxage=1\n' >"$ROOT_DIR/etc/rancher/k3s/config.yaml.d/50-aster-audit.yaml"
c="$(FAKE_BREAK_ON=etc/rancher/k3s/aster/audit-policy.yaml run apply audit)"
[[ "$c" == 1 && "$(cat "$ROOT_DIR/etc/rancher/k3s/config.yaml.d/50-aster-audit.yaml")" == *maxage=1* ]] &&
  pass "回滚恢复被覆盖的旧文件（备份）" || fail "回滚恢复旧文件" "$c $(cat "$ROOT_DIR/etc/rancher/k3s/config.yaml.d/50-aster-audit.yaml" 2>/dev/null)"
fresh; run apply audit,oidc >/dev/null; : >"$WORK/log"; c="$(run rollback oidc)"
[[ "$c" == 0 ]] && ! installed 60-aster-oidc.yaml && installed 50-aster-audit.yaml && [[ "$(restarts)" == 1 ]] &&
  pass "rollback_removes_files_and_restarts（只动所选组件）" || fail rollback_removes_files_and_restarts "$c $(cat "$WORK/out")"

echo "== verify"
fresh; run apply audit --no-restart >/dev/null; printf 'msg="Running kube-apiserver --advertise-address=x"\n' >"$STATE/journal"
c="$(run verify audit)"; [[ "$c" == 1 ]] && grep -q 'audit-policy-file' "$WORK/out" && pass "verify_audit_requires_flag（参数未生效判失败）" || fail verify_audit_requires_flag "$c"
fresh; c="$(FAKE_JOURNAL_EXTRA='E1116 oidc authenticator: initializing plugin: Get "https://token.actions.githubusercontent.com/.well-known/openid-configuration": dial tcp: i/o timeout' run apply oidc --no-auto-rollback)"
[[ "$c" == 1 ]] && grep -q 'oidc authenticator' "$WORK/out" && pass verify_oidc_fails_on_authenticator_error || fail verify_oidc_fails_on_authenticator_error "$c $(cat "$WORK/out")"
fresh; run apply audit >/dev/null; c="$(run verify audit)"
[[ "$c" == 0 ]] && grep -q 'InvocationID\|inv-1' "$WORK/log" && pass "verify 只看本次启动的日志（_SYSTEMD_INVOCATION_ID）" || fail "verify invocation" "$c $(grep journalctl "$WORK/log")"

echo "== status / 用法"
fresh; c="$(FAKE_LEADER=2 run status)"
[[ "$c" == 0 ]] && grep -q 'leader' "$WORK/out" && grep -q '本节点是 etcd leader' "$WORK/out" && grep -q 'members=3 started=3' "$WORK/out" &&
  pass "status 报告成员、leader 与端点" || fail status "$c $(cat "$WORK/out")"
fresh; c1="$(run)"; c2="$(run apply)"; c3="$(run apply nope)"; c4="$(run frob)"; c5="$(run apply audit --bogus)"
[[ "$c1 $c2 $c3 $c4 $c5" == "2 2 2 2 2" ]] && pass usage_errors_exit_2 || fail usage_errors_exit_2 "$c1 $c2 $c3 $c4 $c5"

if [[ "$FAILED" != 0 ]]; then echo "node.test.sh：有用例失败" >&2; exit 1; fi
echo "node.test.sh：全部通过"
