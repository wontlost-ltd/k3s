#!/usr/bin/env bash
# direct-connect-probe.sh 的表驱动测试（aster-api ADR 0054 §12 D7）。离线：PATH 注入假 kubectl（testdata/bin），
# 夹具在 testdata/kubectl/base，每个用例只写覆盖的文件。用法：bash scripts/guard-bypass/direct-connect-probe.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$HERE/direct-connect-probe.sh"
export FAKE_BASE="$HERE/testdata/kubectl/base"
export PATH="$HERE/testdata/bin:$PATH"
export PROBE_NOW_EPOCH=1800000000 # 2027-01-15T08:00:00Z
export PROBE_POLL_SECONDS=0.1 PROBE_POD_TIMEOUT=1 AUTH_POLL_SECONDS=0.1
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
IMAGE="docker.io/curlimages/curl:8.17.0@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40"
NET=(network --agents-ns aster-agents --tool-ns aster-tools --tool-selector app=demo-tool --tool-svc demo-tool:8080
  --admit-ns aster-guard --probe-image "$IMAGE" --positive-url http://aster-guard-mcp.aster-guard.svc.cluster.local:8080/healthz
  --canary-proxy http://aster-guard-mcp.aster-guard.svc.cluster.local:8080/mcp --canary-secret guard-demo-agent --run-id t1)
AUTH=(auth-status --guard-ns aster-guard --cronjob guard-auth-probe --since 2027-01-15T08:00:00Z --wait 2)

# new_case <名称>：建用例目录（覆盖夹具写到 $CASE/），清空输出目录。
new_case() {
  NAME="$1"
  export FAKE_CASE="$WORK/$NAME/case" FAKE_OUT="$WORK/$NAME/out"
  mkdir -p "$FAKE_CASE" "$FAKE_OUT"
  : >"$FAKE_OUT/calls.log"
  CASE="$FAKE_CASE"
}

# run <期望退出码> <参数…>：运行探针，比对退出码；输出存 $OUT，末行摘要存 $SUMMARY。
run() {
  local want="$1"; shift
  local code=0
  OUT="$(bash "$PROBE" "$@" 2>"$FAKE_OUT/stderr")" || code=$?
  SUMMARY="$(tail -n1 <<<"$OUT")"
  if [[ "$code" != "$want" ]]; then
    fail "退出码 $code ≠ 期望 ${want}；stdout=${OUT}；stderr=$(cat "$FAKE_OUT/stderr")"
    return 1
  fi
}

fail() { echo "  ✗ ${NAME}：$*"; FAILED=1; }
ok() { echo "  ✓ $NAME"; }
expect() { local desc="$1"; shift; if "$@"; then :; else fail "$desc"; return 1; fi; }
calls() { cat "$FAKE_OUT/calls.log"; }
no_create() { ! grep -q '^create ' "$FAKE_OUT/calls.log"; }
summary_has() { jq -e "$1" <<<"$SUMMARY" >/dev/null; }

# ── 静态形状违规 → 1，且不建任何 Pod ──
static_violation() {
  new_case "$1"
  cat >"$CASE/${2}"
  run 1 "${NET[@]}" && expect "未创建 Pod" no_create && expect "reasons 含 $3" summary_has ".verdict == \"bypass\" and (.reasons | any(startswith(\"$3\")))" && ok
}

static_violation missing_policy_fails networkpolicies.json no_policy <<'EOF'
{"items":[]}
EOF
static_violation combined_peer_fails networkpolicies.json bad_peer <<'EOF'
{"items":[{"metadata":{"name":"p"},"spec":{"podSelector":{"matchLabels":{"app":"demo-tool"}},"policyTypes":["Ingress"],
 "ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"aster-guard"}},"podSelector":{"matchLabels":{"app":"aster-guard-mcp"}}}],"ports":[{"protocol":"TCP","port":8080}]}]}}]}
EOF
static_violation ipblock_peer_fails networkpolicies.json bad_peer <<'EOF'
{"items":[{"metadata":{"name":"p"},"spec":{"podSelector":{"matchLabels":{"app":"demo-tool"}},"policyTypes":["Ingress"],
 "ingress":[{"from":[{"ipBlock":{"cidr":"10.42.0.0/16"}}],"ports":[{"protocol":"TCP","port":8080}]}]}}]}
EOF
static_violation second_policy_admitting_agents_fails networkpolicies.json bad_peer <<'EOF'
{"items":[
 {"metadata":{"name":"demo-tool-ingress"},"spec":{"podSelector":{"matchLabels":{"app":"demo-tool"}},"policyTypes":["Ingress"],
  "ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"aster-guard"}}}],"ports":[{"protocol":"TCP","port":8080}]}]}},
 {"metadata":{"name":"sneaky"},"spec":{"podSelector":{},"policyTypes":["Ingress"],
  "ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"aster-agents"}}}],"ports":[{"protocol":"TCP","port":8080}]}]}}]}
EOF
static_violation empty_from_fails networkpolicies.json empty_from <<'EOF'
{"items":[{"metadata":{"name":"p"},"spec":{"podSelector":{"matchLabels":{"app":"demo-tool"}},"policyTypes":["Ingress"],"ingress":[{"ports":[{"protocol":"TCP","port":8080}]}]}}]}
EOF
static_violation all_ports_fails networkpolicies.json bad_ports <<'EOF'
{"items":[{"metadata":{"name":"p"},"spec":{"podSelector":{"matchLabels":{"app":"demo-tool"}},"policyTypes":["Ingress"],
 "ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"aster-guard"}}}]}]}}]}
EOF
static_violation implicit_egress_fails networkpolicies.json policy_types <<'EOF'
{"items":[{"metadata":{"name":"p"},"spec":{"podSelector":{"matchLabels":{"app":"demo-tool"}},
 "ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"aster-guard"}}}],"ports":[{"protocol":"TCP","port":8080}]}],
 "egress":[{"to":[{"ipBlock":{"cidr":"0.0.0.0/0"}}]}]}}]}
EOF
static_violation egress_type_without_rules_fails networkpolicies.json policy_types <<'EOF'
{"items":[{"metadata":{"name":"p"},"spec":{"podSelector":{"matchLabels":{"app":"demo-tool"}},"policyTypes":["Egress","Ingress"],
 "ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"aster-guard"}}}],"ports":[{"protocol":"TCP","port":8080}]}]}}]}
EOF
static_violation match_expressions_selector_fails networkpolicies.json unsupported_selector <<'EOF'
{"items":[{"metadata":{"name":"p"},"spec":{"podSelector":{"matchExpressions":[{"key":"app","operator":"Exists"}]},"policyTypes":["Ingress"],"ingress":[]}}]}
EOF
static_violation agents_namespace_with_sa_binding_fails rolebindings.json agents_sa_binding <<'EOF'
{"items":[{"metadata":{"name":"oops"},"subjects":[{"kind":"ServiceAccount","name":"default"}]}]}
EOF
static_violation ticket_check_off_in_deployment_fails deployment.json ticket_check_off <<'EOF'
{"metadata":{"name":"demo-tool"},"spec":{"replicas":1,"strategy":{"type":"Recreate"},
 "template":{"spec":{"containers":[{"name":"demo-tool","env":[{"name":"TICKET_CHECK","value":"off"}]}]}}}}
EOF
static_violation tool_replicas_two_fails deployment.json tool_replicas <<'EOF'
{"metadata":{"name":"demo-tool"},"spec":{"replicas":2,"strategy":{"type":"Recreate"},"template":{"spec":{"containers":[{"name":"demo-tool"}]}}}}
EOF

# ── 动态：两个 Pod、四个目标 ──
new_case probe_runs_same_and_cross_node_against_svc_and_pod_ip
if run 0 "${NET[@]}"; then
  s="$FAKE_OUT/created-0.json"; c="$FAKE_OUT/created-1.json"
  expect "same Pod nodeSelector = 工具节点" jq -e '.spec.nodeSelector["kubernetes.io/hostname"] == "worker-1" and .spec.affinity == null' "$s" >/dev/null &&
  expect "cross Pod 对工具 Pod 反亲和" jq -e '.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0]
      | .namespaces == ["aster-tools"] and .topologyKey == "kubernetes.io/hostname" and .labelSelector.matchLabels == {"app":"demo-tool"}' "$c" >/dev/null &&
  expect "两个目标：Service DNS 与 Pod IP" jq -e '.spec.containers[0].env[] | select(.name == "TARGETS")
      | .value == "http://demo-tool.aster-tools.svc.cluster.local:8080/mcp http://10.42.3.17:8080/mcp"' "$s" >/dev/null &&
  expect "restricted 字段" jq -e '.spec.automountServiceAccountToken == false and .spec.securityContext.runAsNonRoot and
      .spec.securityContext.seccompProfile.type == "RuntimeDefault" and .spec.activeDeadlineSeconds == 90 and .spec.restartPolicy == "Never" and
      (.spec.containers[0].securityContext | .allowPrivilegeEscalation == false and .readOnlyRootFilesystem and .capabilities.drop == ["ALL"])' "$s" >/dev/null &&
  expect "标签带 run-id" jq -e '.metadata.labels == {"app.kubernetes.io/name":"guard-bypass-probe","guard-bypass/run-id":"t1","guard-bypass/path":"same"}' "$s" >/dev/null &&
  expect "只有 cross Pod 带金丝雀 token（secretKeyRef guard-demo-agent/token）" bash -c "
      jq -e '[.spec.containers[0].env[] | select(.valueFrom)] == []' '$s' >/dev/null &&
      jq -e '.spec.containers[0].env[] | select(.name == \"CANARY_TOKEN\") | .valueFrom.secretKeyRef == {\"name\":\"guard-demo-agent\",\"key\":\"token\"}' '$c' >/dev/null" &&
  expect "四个 RESULT" summary_has '.verdict == "pass" and (.results | length) == 4 and ([.results[].path] | sort) == ["cross","cross","same","same"]' &&
  ok
fi

# 探针 Pod 内脚本本身：先被挡、后可达的目标必须记为可达（kube-router 同步延迟不得造成假「挡住」）；
# 一直被挡的目标试满 ATTEMPTS 次。用假 curl（按目标逐次消费退出码）在本机 sh 里运行 Pod 规格中的脚本。
new_case pod_script_retries_and_reports_any_reachable
if run 0 "${NET[@]}"; then
  mkdir -p "$WORK/podbin"
  cat >"$WORK/podbin/curl" <<'SH'
#!/bin/sh
for a; do url=$a; done
echo "$url" >>"$PODCURL_LOG"
key=$(echo "$url" | tr -c 'a-z0-9' '_')
seq="$PODCURL_DIR/$key"
if [ -s "$seq" ]; then rc=$(head -n1 "$seq"); sed '1d' "$seq" >"$seq.t"; mv "$seq.t" "$seq"; else rc=7; fi
[ "$rc" = 0 ] && printf 401
exit "$rc"
SH
  chmod +x "$WORK/podbin/curl"
  export PODCURL_DIR="$WORK/podcurl" PODCURL_LOG="$WORK/podcurl.log"
  mkdir -p "$PODCURL_DIR"; : >"$PODCURL_LOG"
  printf '7\n0\n' >"$PODCURL_DIR/$(echo 'http://demo-tool.aster-tools.svc.cluster.local:8080/mcp' | tr -c 'a-z0-9' '_')"
  script="$(jq -r '.spec.containers[0].command[2]' "$FAKE_OUT/created-0.json")"
  targets="$(jq -r '.spec.containers[0].env[] | select(.name == "TARGETS") | .value' "$FAKE_OUT/created-0.json")"
  log="$(PATH="$WORK/podbin:$PATH" SETTLE_SECONDS=0 RETRY_SECONDS=0 TARGETS="$targets" RUN_ID=t1 sh -c "$script")"
  expect "先被挡后可达 → RESULT 退出码 0" grep -q '^RESULT http://demo-tool.aster-tools.svc.cluster.local:8080/mcp 0 401$' <<<"$log" &&
  expect "一直被挡 → 试满 3 次后记 7" grep -q '^RESULT http://10.42.3.17:8080/mcp 7 000$' <<<"$log" &&
  expect "被挡的目标恰好试 3 次" bash -c "[[ \$(grep -c '10.42.3.17' '$PODCURL_LOG') == 3 ]]" &&
  expect "日志以 DONE 结尾" bash -c "tail -n1 <<<'$log' | grep -q '^DONE$'" && ok
fi

new_case all_blocked_is_pass
run 0 "${NET[@]}" && expect "pass" summary_has '.verdict == "pass" and .canary == {"echo":"ok","delete":"ok"}' && ok

new_case cross_pod_on_tool_node_is_inconclusive
sed 's/"master-1"/"worker-1"/' "$FAKE_BASE/probe-run.json" >"$CASE/probe-run.json"
run 3 "${NET[@]}" && expect "原因：跨节点未覆盖" summary_has '.reasons | any(contains("跨节点路径未覆盖"))' && ok

new_case any_reachable_is_bypass
sed 's#^RESULT http://demo-tool.aster-tools.svc.cluster.local:8080/mcp 7 000#RESULT http://demo-tool.aster-tools.svc.cluster.local:8080/mcp 0 401#' "$FAKE_BASE/log-cross.txt" >"$CASE/log-cross.txt"
run 1 "${NET[@]}" && expect "401 也算可达" summary_has '.verdict == "bypass" and (.results | any(.class == "reachable" and .httpCode == "401"))' && ok

new_case dns_failure_is_inconclusive
sed 's#^RESULT http://demo-tool.aster-tools.svc.cluster.local:8080/mcp 28 000#RESULT http://demo-tool.aster-tools.svc.cluster.local:8080/mcp 6 000#' "$FAKE_BASE/log-same.txt" >"$CASE/log-same.txt"
run 3 "${NET[@]}" && expect "inconclusive" summary_has '.verdict == "inconclusive"' && ok

new_case positive_control_failure_is_inconclusive
sed 's/^POSITIVE 0 200/POSITIVE 7 000/' "$FAKE_BASE/log-cross.txt" >"$CASE/log-cross.txt"
run 3 "${NET[@]}" && expect "原因：正向对照" summary_has '.reasons | any(contains("正向对照"))' && ok

new_case canary_failure_is_inconclusive
sed 's/^CANARY echo ok/CANARY echo fail/' "$FAKE_BASE/log-cross.txt" >"$CASE/log-cross.txt"
run 3 "${NET[@]}" && expect "原因：金丝雀" summary_has '.reasons | any(contains("金丝雀 demo_echo"))' && ok

new_case truncated_log_is_inconclusive
grep -v '^DONE$' "$FAKE_BASE/log-same.txt" >"$CASE/log-same.txt"
run 3 "${NET[@]}" && ok

new_case malformed_result_line_is_inconclusive
sed 's#^RESULT http://10.42.3.17:8080/mcp 28 000#RESULT http://10.42.3.17:8080/mcp x 000#' "$FAKE_BASE/log-same.txt" >"$CASE/log-same.txt"
run 3 "${NET[@]}" && expect "原因：行格式异常" summary_has '.reasons | any(contains("格式异常"))' && ok

new_case duplicate_result_target_is_inconclusive
sed 's#^RESULT http://10.42.3.17:8080/mcp 28 000#RESULT http://demo-tool.aster-tools.svc.cluster.local:8080/mcp 28 000#' "$FAKE_BASE/log-same.txt" >"$CASE/log-same.txt"
run 3 "${NET[@]}" && expect "原因：目标不符" summary_has '.reasons | any(contains("目标与期望不符"))' && ok

new_case run_query_failure_is_inconclusive
touch "$CASE/run-query-fails"
run 3 "${NET[@]}" && expect "phases=query-failed" summary_has '.reasons | any(contains("query-failed"))' && ok

new_case pod_not_scheduled_is_inconclusive
sed 's/"Succeeded"/"Pending"/g' "$FAKE_BASE/probe-run.json" >"$CASE/probe-run.json"
run 3 "${NET[@]}" && expect "原因：未成功结束" summary_has '.reasons | any(contains("未在时限内成功结束"))' && ok

new_case create_rejected_is_inconclusive
touch "$CASE/create-fails"
run 3 "${NET[@]}" && expect "仍按 run-id 清理" grep -q '^delete pod -n aster-agents -l guard-bypass/run-id=t1 --wait=false$' "$FAKE_OUT/calls.log" && ok

new_case cleanup_deletes_by_run_id_on_failure
sed 's/"Succeeded"/"Failed"/' "$FAKE_BASE/probe-run.json" >"$CASE/probe-run.json"
run 3 "${NET[@]}" && expect "trap 按 run-id 删除" grep -q '^delete pod -n aster-agents -l guard-bypass/run-id=t1 --wait=false$' "$FAKE_OUT/calls.log" && ok

new_case stale_probe_pods_are_swept
if run 0 "${NET[@]}"; then
  expect "删除超过 600 s 的残留" grep -q '^delete pod -n aster-agents guard-bypass-probe-old-stale --wait=false$' "$FAKE_OUT/calls.log" &&
  expect "不删新近的" bash -c "! grep -q 'old-fresh' '$FAKE_OUT/calls.log'" &&
  expect "清扫在创建之前" bash -c "grep -n '' '$FAKE_OUT/calls.log' | awk -F: '/old-stale/{d=\$1} /^[0-9]+:create/{if(!c)c=\$1} END{exit !(d && c && d<c)}'" &&
  ok
fi

new_case missing_args_is_usage
run 2 network --agents-ns aster-agents &&
  run 2 "${NET[@]/demo-tool:8080/demo-tool}" &&
  run 2 network --agents-ns a --tool-ns b --tool-selector app=x --tool-svc x:1 --admit-ns c --probe-image curl:latest &&
  run 2 auth-status --guard-ns aster-guard --cronjob guard-auth-probe &&
  run 2 bogus && expect "参数错误不调用 kubectl" bash -c "[[ ! -s '$FAKE_OUT/calls.log' ]]" && ok

new_case dry_run_prints_without_creating
run 0 "${NET[@]}" --dry-run &&
  expect "零写操作" bash -c "! grep -Eq '^(create|delete|logs) ' '$FAKE_OUT/calls.log'" &&
  expect "打印两个 Pod" grep -q '"guard-bypass-probe-t1-cross"' "$FAKE_OUT/stderr" && ok

# ── auth-status ──
for v in pass:0 bypass:1 inconclusive:3; do
  new_case "auth_status_maps_verdict_${v%%:*}"
  sed "s/\"verdict\":\"pass\"/\"verdict\":\"${v%%:*}\"/" "$FAKE_BASE/job-log.txt" >"$CASE/job-log.txt"
  run "${v##*:}" "${AUTH[@]}" && expect "取 since 之后最早的 Job" summary_has '.job == "guard-auth-probe-29000002"' && ok
done

new_case auth_status_non_json_is_inconclusive
echo "curl: (6) Could not resolve host" >"$CASE/job-log.txt"
run 3 "${AUTH[@]}" && ok

new_case auth_status_pod_query_failure_is_inconclusive
touch "$CASE/job-pods-fails"
run 3 "${AUTH[@]}" && ok

new_case auth_status_two_pods_is_inconclusive
jq '.items += [.items[0] | .metadata.name = "guard-auth-probe-29000002-zzzzz"]' "$FAKE_BASE/job-pods.json" >"$CASE/job-pods.json"
run 3 "${AUTH[@]}" && ok

new_case auth_status_timeout_is_inconclusive
echo '{"items":[]}' >"$CASE/jobs.json"
run 3 "${AUTH[@]}" && expect "原因：等待超时" summary_has '.reasons | any(contains("等待超时"))' && ok

new_case auth_status_waits_for_running_job
jq '.items[1].status = {"startTime":"2027-01-15T08:10:00Z","active":1}' "$FAKE_BASE/jobs.json" >"$CASE/jobs.json"
run 3 "${AUTH[@]}" && expect "未结束不读日志" bash -c "! grep -q '^logs ' '$FAKE_OUT/calls.log'" && ok

if [[ "$FAILED" != 0 ]]; then
  echo "direct-connect-probe.test.sh：有用例失败" >&2
  exit 1
fi
echo "direct-connect-probe.test.sh：全部通过"
