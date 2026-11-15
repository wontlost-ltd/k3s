#!/usr/bin/env bash
# guard-bypass-probe.yml 与其辅助脚本的测试（计划 Task 8）。离线：yq + jq，假 kubectl。
# 用法：bash scripts/guard-bypass/workflow.test.sh
# shellcheck disable=SC2016,SC2015  # 单引号内是 yq / jq 表达式；pass 恒成功，A && pass || fail 即 if-else
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WF="$ROOT/.github/workflows/guard-bypass-probe.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1${2:+：$2}"; FAILED=1; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
yqe() { [[ "$(yq "$1" "$WF")" == "$2" ]]; }

echo "== 工作流形状"
check "触发恰为 push(main) / schedule / workflow_dispatch" yqe '.on | keys | sort | join(",")' 'push,schedule,workflow_dispatch'
check "push 只在 main" yqe '.on.push.branches | join(",")' 'main'
check "不含任何 PR 类事件或 pull_request_target（全文，注释除外）" bash -c "! grep -v '^[[:space:]]*#' '$WF' | grep -Eq '(^|[^a-z_])(pull_request(_target)?|workflow_run|issue_comment)([^a-z_]|\$)'"
check "工作流级权限只有 contents: read，全文无 id-token" bash -c "[[ \"\$(yq -o=json -I=0 '.permissions' '$WF')\" == '{\"contents\":\"read\"}' ]] && ! grep -q 'id-token' '$WF'"
check "probe job：if main、environment guard-probe" bash -c "[[ \"\$(yq '.jobs.probe.if' '$WF')\" == \"github.ref == 'refs/heads/main'\" && \"\$(yq '.jobs.probe.environment' '$WF')\" == guard-probe ]]"
check "全仓只有本文件引用 Environment guard-probe 与 GUARD_PROBE_KUBECONFIG" bash -c "
  cd '$ROOT/.github/workflows'
  [[ \"\$(grep -l 'GUARD_PROBE_KUBECONFIG' -- *.yml *.yaml 2>/dev/null)\" == guard-bypass-probe.yml ]] &&
  [[ \"\$(grep -lE 'guard-probe([^-]|\$)' -- *.yml *.yaml 2>/dev/null | sort -u)\" == guard-bypass-probe.yml ]]"
check "所有 checkout 都 persist-credentials: false" bash -c "[[ \"\$(yq '[.jobs[].steps[] | select(.uses | test(\"^actions/checkout@\")) | .with.\"persist-credentials\"] | all_c(. == false)' '$WF')\" == true ]]"
check "auth whoami 校验探针身份" bash -c "yq '.jobs.probe.steps[].run' '$WF' | grep -q 'auth whoami' && grep -q 'system:serviceaccount:aster-guard:guard-bypass-probe' '$WF'"
check "secret 只在写入步骤出现，且从不 echo / cat kubeconfig" bash -c "
  [[ \"\$(yq '[.jobs.probe.steps[] | select(tostring | test(\"secrets.GUARD_PROBE_KUBECONFIG\")) | .name] | join(\",\")' '$WF')\" == 'Write probe kubeconfig' ]] &&
  ! grep -v '^[[:space:]]*#' '$WF' | grep -Eq '(echo|cat|tee)[^|]*[$][{]?GUARD_PROBE_KUBECONFIG|cat [^|]*kubeconfig|set -x'"
check "每个下载都校验 sha256" bash -c "
  run=\"\$(yq '.jobs.probe.steps[] | select(.name | test(\"^Install\")) | .run' '$WF')\"
  [[ \$(grep -c 'curl -fsSL -o' <<<\"\$run\") -ge 4 && \$(grep -c 'curl -fsSL -o' <<<\"\$run\") == \$(grep -c 'sha256sum -c -' <<<\"\$run\") ]]"
check "生产探针不传 --no-tool-shape-check，且带金丝雀" bash -c "! grep -v '^[[:space:]]*#' '$WF' | grep -q -- '--no-tool-shape-check' && grep -q -- '--canary-proxy' '$WF'"
check "kubeconfig 用后删除（always）" bash -c "[[ \"\$(yq '.jobs.probe.steps[] | select(.name == \"Remove kubeconfig\") | .if' '$WF')\" == 'always()' ]]"
check "watchdog：仅 schedule，权限只有 actions: read" bash -c "[[ \"\$(yq '.jobs.watchdog.if' '$WF')\" == \"github.event_name == 'schedule'\" && \"\$(yq -o=json -I=0 '.jobs.watchdog.permissions' '$WF')\" == '{\"actions\":\"read\"}' ]]"

echo "== token-expiry"
jwt() { # jwt <iat> <exp>
  local h p
  h="$(printf '{"alg":"RS256"}' | base64 | tr -d '=\n' | tr '/+' '_-')"
  p="$(printf '{"iss":"k3s","sub":"system:serviceaccount:aster-guard:guard-bypass-probe","iat":%s,"exp":%s}' "$1" "$2" | base64 | tr -d '=\n' | tr '/+' '_-')"
  printf '%s.%s.sig' "$h" "$p"
}
NOW=1800000000 DAY=86400
expiry() { local out code=0; out="$(jwt "$1" "$2" | bash "$HERE/token-expiry.sh" "$NOW" 2>&1)" || code=$?; echo "$code|$out"; }
r="$(expiry $((NOW - 31 * DAY)) $((NOW - DAY)))"; [[ "$r" == 3\|*已过期* ]] && pass "token_expiry_expired_is_3" || fail token_expiry_expired_is_3 "$r"
r="$(expiry $((NOW - 20 * DAY)) $((NOW + 10 * DAY)))"; [[ "$r" == 0\|*::warning::*10\ 天后过期* ]] && pass "token_expiry_warning（剩 10 天告警）" || fail token_expiry_warning "$r"
r="$(expiry $((NOW - 20 * DAY)) $((NOW + 60 * DAY)))"; [[ "$r" == 0\|* && "$r" != *::warning::* ]] && pass "token_expiry_60_days_ok" || fail token_expiry_60_days_ok "$r"
r="$(expiry $((NOW - DAY)) $((NOW + 364 * DAY)))"; [[ "$r" == 3\|*超过\ 90\ 天上限* ]] && pass "token_lifetime_over_90d_is_3" || fail token_lifetime_over_90d_is_3 "$r"
r="$(expiry $((NOW + DAY)) $((NOW + DAY)))"; [[ "$r" == 3\|* ]] && pass "token_nonpositive_lifetime_is_3" || fail token_nonpositive_lifetime_is_3 "$r"
r="$(printf 'not-a-jwt' | bash "$HERE/token-expiry.sh" "$NOW" 2>&1; echo "|$?")"; [[ "$r" == *"|3" ]] && pass "token_unparseable_is_3" || fail token_unparseable_is_3 "$r"

echo "== watchdog"
wd() { local code=0; bash "$HERE/watchdog.sh" "$NOW" "$1" >/dev/null 2>&1 || code=$?; echo "$code"; }
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
mk() { # mk <file> <latest-conclusion> <latest-completed-epoch> [older-success]
  jq -n --arg c "$2" --arg t "$(iso "$3")" --arg old "$(iso $((NOW - 3 * DAY)))" --arg o "${4:-}" '{
    workflow_runs: ([{id: 2, updated_at: $t, html_url: "run-2"}] + (if $o == "" then [] else [{id: 1, updated_at: $old, html_url: "run-1"}] end)),
    latest_jobs: {jobs: [{name: "probe", conclusion: $c, completed_at: $t}, {name: "watchdog", conclusion: "success", completed_at: $t}]}}' >"$1"
}
mk "$WORK/w1.json" success $((NOW - 3600)); [[ "$(wd "$WORK/w1.json")" == 0 ]] && pass watchdog_recent_success_passes || fail watchdog_recent_success_passes
mk "$WORK/w2.json" failure $((NOW - 3600)) older; [[ "$(wd "$WORK/w2.json")" == 1 ]] && pass watchdog_latest_failed_after_older_success_fails || fail watchdog_latest_failed_after_older_success_fails
mk "$WORK/w3.json" success $((NOW - 37 * 3600)); [[ "$(wd "$WORK/w3.json")" == 1 ]] && pass watchdog_stale_fails || fail watchdog_stale_fails
: >"$WORK/w4.json"; [[ "$(wd "$WORK/w4.json")" == 1 ]] && pass watchdog_api_error_fails || fail watchdog_api_error_fails
echo '{"workflow_runs":[],"latest_jobs":{"jobs":[]}}' >"$WORK/w5.json"; [[ "$(wd "$WORK/w5.json")" == 1 ]] && pass watchdog_no_runs_fails || fail watchdog_no_runs_fails
mk "$WORK/w6.json" skipped $((NOW - 3600)); [[ "$(wd "$WORK/w6.json")" == 1 ]] && pass watchdog_skipped_probe_fails || fail watchdog_skipped_probe_fails

echo "== kubeconfig-for-probe"
mkdir -p "$WORK/kbin"
cat >"$WORK/kbin/kubectl" <<'SH'
#!/usr/bin/env bash
# 假 kubectl：create token → $FAKE_TOKEN；CA → base64("CA")；config set-* → 写目标文件；auth whoami → $FAKE_WHO。
echo "$*" >>"$FAKE_LOG"
args=("$@"); kc=""
if [[ "${args[0]}" == --kubeconfig ]]; then kc="${args[1]}"; args=("${args[@]:2}"); fi
case "${args[*]}" in
  "create token"*) printf '%s' "$FAKE_TOKEN" ;;
  "config view --raw --minify"*) printf 'CA' | base64 ;;
  "config "*) echo "${args[*]}" >>"$kc" ;;
  "auth whoami"*) printf '%s' "$FAKE_WHO" ;;
  *) exit 99 ;;
esac
SH
chmod +x "$WORK/kbin/kubectl"
kc() { # kc <duration> <token> <who> → 退出码|调用次数
  local code=0
  : >"$WORK/klog"
  FAKE_LOG="$WORK/klog" FAKE_TOKEN="$2" FAKE_WHO="$3" KUBECTL="$WORK/kbin/kubectl" \
    bash "$HERE/kubeconfig-for-probe.sh" --server https://158.179.18.241:6443 --duration "$1" >"$WORK/kout" 2>/dev/null || code=$?
  echo "$code|$(wc -l <"$WORK/klog" | tr -d ' ')"
}
GOOD_WHO=system:serviceaccount:aster-guard:guard-bypass-probe
r="$(kc 2200h "$(jwt "$NOW" $((NOW + 30 * DAY)))" "$GOOD_WHO")"; [[ "$r" == "2|0" ]] && pass duration_over_90d_is_rejected || fail duration_over_90d_is_rejected "$r"
r="$(kc 720h "$(jwt "$NOW" $((NOW + 365 * DAY)))" "$GOOD_WHO")"; [[ "$r" == 1\|* && ! -s "$WORK/kout" ]] && pass issued_token_longer_than_90d_is_rejected || fail issued_token_longer_than_90d_is_rejected "$r"
r="$(kc 720h "$(jwt "$NOW" $((NOW + 30 * DAY)))" system:admin)"; [[ "$r" == 1\|* && ! -s "$WORK/kout" ]] && pass non_probe_identity_is_rejected || fail non_probe_identity_is_rejected "$r"
r="$(kc 720h "$(jwt "$NOW" $((NOW + 30 * DAY)))" "$GOOD_WHO")"
if [[ "$r" == 0\|* ]] && base64 -d <"$WORK/kout" | grep -q 'set-credentials guard-bypass-probe'; then pass "合规凭证输出 base64 kubeconfig"; else fail "合规凭证输出 base64 kubeconfig" "$r"; fi

echo "== converge"
# 夹具树：复制 apps/aster-lang/{guard,tools}，把镜像 digest 改写成已知值——用例不依赖仓库里当前 pin 的 digest。
# （converge.sh 在生产照常读真实的渲染结果；只有测试换根目录。）
FIX="$WORK/fixture-root"
mkdir -p "$FIX/apps/aster-lang"
cp -R "$ROOT/apps/aster-lang/guard" "$ROOT/apps/aster-lang/tools" "$FIX/apps/aster-lang/"
PROXY_DIGEST="sha256:$(printf 'a%.0s' {1..64})"
TOOL_DIGEST="sha256:$(printf 'b%.0s' {1..64})"
yq -i "(.images[] | select(.name == \"docker.io/wontlost/aster-guard-mcp\")).digest = \"$PROXY_DIGEST\"" "$FIX/apps/aster-lang/guard/kustomization.yaml"
yq -i "(.images[] | select(.name == \"docker.io/wontlost/aster-guard-demo-tool\")).digest = \"$TOOL_DIGEST\"" "$FIX/apps/aster-lang/tools/kustomization.yaml"
# 假 kubectl：两个应用的 Pod imageID 分别取 $FAKE_PROXY_DIGEST / $FAKE_TOOL_DIGEST，Deployment 可用副本取 $FAKE_AVAIL，
# 策略 spec 取渲染结果（或被篡改的版本）。
cat >"$WORK/kbin/kubectl-conv" <<'SH'
#!/usr/bin/env bash
pod() { jq -n --arg id "docker.io/wontlost/x@$1" --argjson n "${FAKE_PODS:-1}" \
  '{items: [range($n) | {metadata: {}, status: {phase: "Running", containerStatuses: [{imageID: $id}]}}]}'; }
case "$*" in
  "get pods -n aster-guard -l app=aster-guard-mcp -o json") pod "$FAKE_PROXY_DIGEST" ;;
  "get pods -n aster-tools -l app=demo-tool -o json") pod "$FAKE_TOOL_DIGEST" ;;
  "get deployment -n "*" -o json")
    jq -n --argjson a "$FAKE_AVAIL" --argjson og "${FAKE_OBSERVED:-2}" \
      '{metadata: {generation: 2}, spec: {replicas: 1}, status: {observedGeneration: $og, updatedReplicas: 1, availableReplicas: $a}}' ;;
  "get networkpolicy -n aster-tools demo-tool-ingress -o json") cat "$FAKE_NP" ;;
  *) echo "unexpected $*" >&2; exit 99 ;;
esac
SH
chmod +x "$WORK/kbin/kubectl-conv"
kustomize build "$FIX/apps/aster-lang/tools" | yq 'select(.kind == "NetworkPolicy")' -o=json >"$WORK/np.json"
jq '.spec.ingress[0].ports[0].port = 9090' "$WORK/np.json" >"$WORK/np-bad.json"
# conv <proxy digest> <tool digest> <available> <policy file>
conv() { local code=0; KUBECTL="$WORK/kbin/kubectl-conv" FAKE_PROXY_DIGEST="$1" FAKE_TOOL_DIGEST="$2" FAKE_AVAIL="$3" FAKE_NP="$4" \
  CONVERGE_TIMEOUT=1 CONVERGE_POLL=0.2 bash "$HERE/converge.sh" "$FIX" >"$WORK/conv.out" 2>/dev/null || code=$?; echo "$code"; }
OTHER="sha256:$(printf 'c%.0s' {1..64})"
[[ "$(conv "$PROXY_DIGEST" "$TOOL_DIGEST" 1 "$WORK/np.json")" == 0 ]] && grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$WORK/conv.out" &&
  pass "converge_prints_since_when_matching" || fail converge_prints_since_when_matching "$(cat "$WORK/conv.out")"
[[ "$(conv "$OTHER" "$TOOL_DIGEST" 1 "$WORK/np.json")" == 3 ]] && pass converge_proxy_digest_mismatch_times_out || fail converge_proxy_digest_mismatch_times_out
[[ "$(conv "$PROXY_DIGEST" "$OTHER" 1 "$WORK/np.json")" == 3 ]] && pass converge_tool_digest_mismatch_times_out || fail converge_tool_digest_mismatch_times_out
[[ "$(conv "$TOOL_DIGEST" "$PROXY_DIGEST" 1 "$WORK/np.json")" == 3 ]] && pass converge_swapped_digests_time_out || fail converge_swapped_digests_time_out
[[ "$(conv "$PROXY_DIGEST" "$TOOL_DIGEST" 0 "$WORK/np.json")" == 3 ]] && pass converge_unavailable_times_out || fail converge_unavailable_times_out
[[ "$(conv "$PROXY_DIGEST" "$TOOL_DIGEST" 1 "$WORK/np-bad.json")" == 3 ]] && pass converge_policy_drift_times_out || fail converge_policy_drift_times_out
[[ "$(FAKE_PODS=2 conv "$PROXY_DIGEST" "$TOOL_DIGEST" 1 "$WORK/np.json")" == 3 ]] && pass converge_two_pods_times_out || fail converge_two_pods_times_out
[[ "$(FAKE_OBSERVED=1 conv "$PROXY_DIGEST" "$TOOL_DIGEST" 1 "$WORK/np.json")" == 3 ]] && pass converge_unobserved_generation_times_out || fail converge_unobserved_generation_times_out

if [[ "$FAILED" != 0 ]]; then echo "workflow.test.sh：有用例失败" >&2; exit 1; fi
echo "workflow.test.sh：全部通过"
