#!/usr/bin/env bash
# redteam-window.sh 的离线测试（计划 Task 10 Step 1）：假 kubectl + 假网络探针，断言映射、取舍、场景顺序与清理。
# 用法：bash scripts/guard-bypass/redteam-window.test.sh
# shellcheck disable=SC2015  # pass 恒成功
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/redteam-window.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1${2:+：$2}"; FAILED=1; }
PROD_NS='aster-(agents|guard|tools)([^-a-z0-9]|$)'

mkdir -p "$WORK/bin"
cat >"$WORK/bin/kubectl" <<'SH'
#!/usr/bin/env bash
# 假 kubectl：记录调用；按子命令回放。FAKE_ROLLOUT_FAIL=1 让 rollout 失败（验证 trap 清理）。
args=("$@"); [[ "${args[0]}" == --kubeconfig ]] && args=("${args[@]:2}")
echo "${args[*]}" >>"$FAKE_LOG"
case "${args[*]}" in
  "get ns -l guard-bypass/redteam-expires -o json")
    jq -n '{items: [{metadata: {name: "aster-rt-1-agents", labels: {"guard-bypass/redteam-expires": "1"}}},
                    {metadata: {name: "aster-rt-9-agents", labels: {"guard-bypass/redteam-expires": "9999999999"}}}]}' ;;
  "apply -f -") cat >>"$FAKE_APPLIED" ;;
  "create -f -") cat >>"$FAKE_JOBS" ;;
  "rollout status"*) [[ "${FAKE_ROLLOUT_FAIL:-0}" != 1 ]] ;;
  "get job -n "*) echo '{"status":{"succeeded":1}}' ;;
  "logs -n "*auth-probe-ra) echo '{"verdict":"bypass","steps":{"missing":200},"markerExecuted":true}' ;;
  "logs -n "*) echo '{"verdict":"pass","steps":{"missing":401},"markerExecuted":false}' ;;
  "delete "*|"set env "*) : ;;
  *) echo "fake kubectl：未预期 ${args[*]}" >&2; exit 99 ;;
esac
SH
cat >"$WORK/bin/net-probe" <<'SH'
#!/usr/bin/env bash
# 假网络探针：按 --run-id 后缀给结论；记录参数（检查生产命名空间与 --no-tool-shape-check）。
echo "$*" >>"$FAKE_LOG"
case "$*" in
  *-base*) echo '{"verdict":"pass"}' ;;
  *-rn*) echo '{"verdict":"bypass"}' ;;
  *-ra*--no-tool-shape-check*) echo '{"verdict":"pass"}' ;;
  *) echo '{"verdict":"inconclusive"}' ;;
esac
SH
chmod +x "$WORK/bin/kubectl" "$WORK/bin/net-probe"
export PATH="$WORK/bin:$PATH" REDTEAM_NET_PROBE="$WORK/bin/net-probe" REDTEAM_WATCHDOG=0 REDTEAM_RUN=4242 REDTEAM_POLL=0
export FAKE_LOG="$WORK/calls.log" FAKE_APPLIED="$WORK/applied.json" FAKE_JOBS="$WORK/jobs.json"

echo "== dry-run"
: >"$FAKE_LOG"
bash "$SCRIPT" --kubeconfig /dev/null --dry-run >"$WORK/dry.out"
[[ ! -s "$FAKE_LOG" ]] && pass "dry_run_makes_zero_kubectl_calls" || fail dry_run_makes_zero_kubectl_calls "$(cat "$FAKE_LOG")"
grep -q '真实运行时将先清扫过期红队命名空间' "$WORK/dry.out" && pass "dry-run 说明启动清扫只在真实运行" || fail "dry-run 说明启动清扫"
sed -n '/^# 副本清单/,$p' "$WORK/dry.out" | tail -n +2 >"$WORK/replica.json"
sed -n '/^# 票据探针 Job 模板/,/^# 副本清单/p' "$WORK/dry.out" | sed '1d;$d' >"$WORK/job.json"
# 引用检查不看 ConfigMap 的 data：那是探针脚本正文（注释里提到生产命名空间），不是对象引用。
jq 'map(if .kind == "ConfigMap" then del(.data) else . end)' "$WORK/replica.json" >"$WORK/refs.json"
! grep -Eq "$PROD_NS" "$WORK/refs.json" "$WORK/job.json" && pass "mapped_manifests_have_no_production_namespace" ||
  fail mapped_manifests_have_no_production_namespace "$(grep -Eo ".{20}$PROD_NS" "$WORK/refs.json" "$WORK/job.json" | head -3)"
kinds="$(jq -r '[.[] | .kind] | sort | join(",")' "$WORK/replica.json")"
[[ "$kinds" == "ConfigMap,Deployment,LimitRange,Namespace,Namespace,Namespace,NetworkPolicy,ResourceQuota,Secret,Service" ]] &&
  pass "kept_kinds_match_table（无 Role / RoleBinding / ExternalSecret / CronJob / 代理）" || fail kept_kinds_match_table "$kinds"
jq -e '[.[] | select(.kind == "Secret")] == [{"apiVersion":"v1","kind":"Secret","type":"Opaque","metadata":{"name":"demo-tool-guard","namespace":"aster-rt-4242-tools"},"stringData":{"tool-api-key":"redteam-dummy","tenant-id":"redteam"}}]' "$WORK/replica.json" >/dev/null &&
  pass "唯一 Secret 是字面量 dummy 凭据" || fail "唯一 Secret 是字面量 dummy 凭据"
! grep -q 'TICKET_CHECK' "$WORK/refs.json" && pass "副本清单不含 TICKET_CHECK（只在 R-A 步骤设置）" || fail "副本清单不含 TICKET_CHECK"
jq -e '[.[] | select(.kind == "Namespace") | .metadata.labels["guard-bypass/redteam-run"] == "4242" and (.metadata.labels["guard-bypass/redteam-expires"] | test("^[0-9]+$")) and .metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted"] | all' "$WORK/replica.json" >/dev/null &&
  pass "副本命名空间带 run / expires 标签且保留 PSA restricted" || fail "副本命名空间标签"
jq -e '.spec.template.spec.containers[0].env[] | select(.name == "TOOL_URL") | .value == "http://demo-tool.aster-rt-4242-tools.svc.cluster.local:8080"' "$WORK/job.json" >/dev/null &&
  pass "票据探针 Job 指向副本工具" || fail "票据探针 Job 指向副本工具"
jq -e '.[] | select(.kind == "NetworkPolicy") | .spec.ingress[0].from == [{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"aster-rt-4242-guard"}}}]' "$WORK/replica.json" >/dev/null &&
  pass "副本工具策略只放行副本 guard 命名空间" || fail "副本工具策略"

echo "== 真实运行（假 kubectl）"
: >"$FAKE_LOG"; : >"$FAKE_APPLIED"; : >"$FAKE_JOBS"
code=0; bash "$SCRIPT" --kubeconfig /dev/null >"$WORK/real.out" 2>&1 || code=$?
[[ "$code" == 0 ]] && grep -q '两条反向记录均符合期望' "$WORK/real.out" && pass "六行表全部符合期望" || fail "六行表" "$(tail -9 "$WORK/real.out")"
grep -q '^delete ns aster-rt-1-agents --wait=false$' "$FAKE_LOG" && ! grep -q 'delete ns aster-rt-9-agents' "$FAKE_LOG" &&
  pass "expired_namespaces_are_swept_at_start" || fail expired_namespaces_are_swept_at_start
order="$(grep -nE '^(delete networkpolicy|set env|apply -f -)' "$FAKE_LOG" | cut -d: -f2 | tr '\n' '|')"
[[ "$order" == "apply -f -|delete networkpolicy -n aster-rt-4242-tools demo-tool-ingress|apply -f -|set env deploy/demo-tool -n aster-rt-4242-tools TICKET_CHECK=off|" ]] &&
  pass "TICKET_CHECK=off 只在 R-A（恢复策略之后）设置一次" || fail "场景顺序" "$order"
grep -q -- '-ra.*--no-tool-shape-check' "$FAKE_LOG" && [[ "$(grep -c -- '--no-tool-shape-check' "$FAKE_LOG")" == 1 ]] &&
  pass "--no-tool-shape-check 只用于 R-A 网络探针" || fail "--no-tool-shape-check 用法"
! grep -Eq "$PROD_NS" "$FAKE_LOG" && pass "never_touches_production_namespaces（kubectl 与探针参数）" || fail never_touches_production_namespaces "$(grep -E "$PROD_NS" "$FAKE_LOG" | head -2)"
grep -q '^delete ns aster-rt-4242-agents aster-rt-4242-guard aster-rt-4242-tools --ignore-not-found --wait=false$' "$FAKE_LOG" &&
  pass "结束时删除三个副本命名空间" || fail "结束时删除三个副本命名空间"

echo "== 中途失败"
: >"$FAKE_LOG"
code=0; FAKE_ROLLOUT_FAIL=1 bash "$SCRIPT" --kubeconfig /dev/null >/dev/null 2>&1 || code=$?
[[ "$code" != 0 ]] && grep -q '^delete ns aster-rt-4242-agents aster-rt-4242-guard aster-rt-4242-tools' "$FAKE_LOG" &&
  pass "trap_deletes_three_namespaces_on_failure" || fail trap_deletes_three_namespaces_on_failure

echo "== 启动清扫查询失败"
: >"$FAKE_LOG"
cp "$WORK/bin/kubectl" "$WORK/kubectl.ok"
sed -i.bak 's/^  "get ns -l guard-bypass\/redteam-expires -o json")$/  "get ns -l guard-bypass\/redteam-expires -o json") exit 1 ;;\n  "never")/' "$WORK/bin/kubectl"
code=0; bash "$SCRIPT" --kubeconfig /dev/null >/dev/null 2>&1 || code=$?
[[ "$code" != 0 ]] && ! grep -q '^apply ' "$FAKE_LOG" && grep -q '^delete ns aster-rt-4242-agents aster-rt-4242-guard aster-rt-4242-tools' "$FAKE_LOG" &&
  pass "sweep_query_failure_aborts_before_apply_and_cleans_up" || fail sweep_query_failure_aborts_before_apply_and_cleans_up "$(cat "$FAKE_LOG")"
cp "$WORK/kubectl.ok" "$WORK/bin/kubectl"

echo "== R-A 只看退出码不够"
sed -i.bak 's/"markerExecuted":true/"markerExecuted":false/' "$WORK/bin/kubectl"
code=0; bash "$SCRIPT" --kubeconfig /dev/null >"$WORK/real2.out" 2>&1 || code=$?
[[ "$code" == 1 ]] && grep -q '| R-A | 票据 | 1 | 1 | ✗ |' "$WORK/real2.out" && pass "R-A 票据探针未证明无票据调用执行 → 不符合" || fail "R-A 额外断言" "$(tail -3 "$WORK/real2.out")"

if [[ "$FAILED" != 0 ]]; then echo "redteam-window.test.sh：有用例失败" >&2; exit 1; fi
echo "redteam-window.test.sh：全部通过"
