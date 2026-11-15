#!/usr/bin/env bash
# apps/aster-lang/{agents,guard,tools} 的渲染结果断言（aster-api ADR 0054 §12 D2 / D3 / D9；计划 Task 7 / 7c）。
# 离线：kustomize build + yq + jq。用法：bash scripts/guard-bypass/manifests.test.sh
#
# 这里断言的是 git 里的清单；集群侧另有准入策略（Task 7c）与部署层探针（Task 6 / 8）。
# shellcheck disable=SC2016  # 单引号内是 jq 程序与 bash -c 脚本，$ 不应由本 shell 展开
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/guard-bypass/lib.sh
source "$HERE/lib.sh"
APPS="${GUARD_APPS_ROOT:-$ROOT/apps/aster-lang}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

for t in kustomize yq jq; do command -v "$t" >/dev/null || { echo "缺少 $t" >&2; exit 1; }; done

# 渲染为 JSON 数组：$WORK/<app>.json
for app in agents guard tools; do
  kustomize build "$APPS/$app" | yq -o=json -I=0 '.' | jq -s 'map(select(. != null))' >"$WORK/$app.json" ||
    { echo "  ✗ kustomize build apps/aster-lang/$app 失败"; exit 1; }
done
jq -s 'add' "$WORK/agents.json" "$WORK/guard.json" "$WORK/tools.json" >"$WORK/all.json"

check() {
  local name="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    echo "  ✓ ${name}"
  else
    echo "  ✗ ${name}"
    [[ -z "$out" ]] || while IFS= read -r line; do echo "      ${line}"; done <<<"$out"
    FAILED=1
  fi
}

# jq_none <file> [jq 选项…] <表达式>：表达式输出的每一行都是一条违规；无输出即通过。
jq_none() {
  local file="$1" out
  shift
  out="$(jq -r "$@" "$file")"
  [[ -z "$out" ]] || { echo "$out"; return 1; }
}

check "三个命名空间：PSA restricted（latest）且 sigstore include" jq_none "$WORK/all.json" '
  [.[] | select(.kind == "Namespace")] as $ns
  | (if ($ns | map(.metadata.name) | sort) != ["aster-agents","aster-guard","aster-tools"] then "命名空间集合不符：\($ns | map(.metadata.name))" else empty end),
    ($ns[] | .metadata as $m | $m.labels as $l
      | select($l["pod-security.kubernetes.io/enforce"] != "restricted"
          or $l["pod-security.kubernetes.io/enforce-version"] != "latest"
          or $l["policy.sigstore.dev/include"] != "true")
      | "\($m.name) 标签不符：\($l)")'

check "工具入站策略并集合规（namespace-only、仅 aster-guard、仅 8080/TCP）" bash -c '
  jq "{items: [.[] | select(.kind == \"NetworkPolicy\")]}" "$1" >"$2/policies.json"
  jq "[.[] | select(.kind == \"Deployment\" and .metadata.name == \"demo-tool\")][0].spec.template.metadata.labels" "$1" >"$2/labels.json"
  source "$3/lib.sh"
  out="$(policy_union_violations "$2/policies.json" "$2/labels.json" aster-guard)"
  [[ -z "$out" ]] || { echo "$out"; exit 1; }' _ "$WORK/tools.json" "$WORK" "$HERE"

check "NetworkPolicy 只在 aster-tools（其它两个命名空间不启用策略）" jq_none "$WORK/all.json" '
  .[] | select(.kind == "NetworkPolicy" and (.metadata.namespace != "aster-tools" or .metadata.name != "demo-tool-ingress"))
  | "多余的 NetworkPolicy：\(.metadata.namespace)/\(.metadata.name)"'

check "渲染结果中没有 TICKET_CHECK=off" jq_none "$WORK/all.json" '
  [.. | objects | select(.name? == "TICKET_CHECK")] | .[] | select(.value != "on") | "TICKET_CHECK 被设为 \(.value // .valueFrom | tojson)"'

# 所有 Pod 模板（Deployment / CronJob）满足 restricted 与 Global Constraints「Pod 安全」。
POD_TEMPLATES='[.[] | if .kind == "Deployment" then {o: "\(.metadata.namespace)/\(.metadata.name)", s: .spec.template.spec}
  elif .kind == "CronJob" then {o: "\(.metadata.namespace)/\(.metadata.name)", s: .spec.jobTemplate.spec.template.spec}
  else empty end]'
check "Pod 模板：runAsNonRoot、RuntimeDefault、不挂 SA token、无 host* / hostPath" jq_none "$WORK/all.json" "$POD_TEMPLATES"' | .[] | .o as $o | .s
  | (if .securityContext.runAsNonRoot != true then "\($o)：pod runAsNonRoot 须为 true" else empty end),
    (if .securityContext.seccompProfile.type != "RuntimeDefault" then "\($o)：seccompProfile 须为 RuntimeDefault" else empty end),
    (if .automountServiceAccountToken != false then "\($o)：automountServiceAccountToken 须为 false" else empty end),
    (if (.hostNetwork or .hostPID or .hostIPC) then "\($o)：不得使用 host 命名空间" else empty end),
    ((.volumes // [])[] | select(.hostPath) | "\($o)：不得挂 hostPath")'
check "容器：不提权、drop ALL、只读根文件系统、有 requests / limits" jq_none "$WORK/all.json" "$POD_TEMPLATES"' | .[] | .o as $o
  | ((.s.containers // []) + (.s.initContainers // []))[] | .name as $c | .securityContext as $sc
  | (if $sc.allowPrivilegeEscalation != false then "\($o)/\($c)：allowPrivilegeEscalation 须为 false" else empty end),
    (if $sc.capabilities.drop != ["ALL"] then "\($o)/\($c)：capabilities.drop 须为 [ALL]" else empty end),
    (if ($sc.capabilities.add // []) != [] then "\($o)/\($c)：不得 add capabilities" else empty end),
    (if $sc.readOnlyRootFilesystem != true then "\($o)/\($c)：readOnlyRootFilesystem 须为 true" else empty end),
    (if (.resources.requests == null or .resources.limits == null) then "\($o)/\($c)：须声明 requests 与 limits" else empty end)'

check "所有镜像按 @sha256 引用（探针镜像只在 CronJob 一处）" jq_none "$WORK/all.json" "$POD_TEMPLATES"' | .[] | .o as $o
  | ((.s.containers // []) + (.s.initContainers // []))[] | select(.image | test("@sha256:[0-9a-f]{64}$") | not) | "\($o)：镜像未按 digest：\(.image)"'
check "探针镜像（curlimages/curl）恰出现一次，在 guard-auth-probe，形如 curl:<8.x>@sha256" jq_none "$WORK/all.json" "$POD_TEMPLATES"'
  | [.[] | .o as $o | ((.s.containers // []) + (.s.initContainers // []))[] | select(.image | contains("curlimages/curl")) | {o: $o, image}] as $c
  | if ($c | length) != 1 or $c[0].o != "aster-guard/guard-auth-probe"
       or ($c[0].image | test("^docker.io/curlimages/curl:8[.][0-9]+[.][0-9]+@sha256:[0-9a-f]{64}$") | not)
    then "探针镜像引用不符：\($c)" else empty end'

check "demo-tool：replicas ≤ 1 且 Recreate；代理 --isolation network,auth" jq_none "$WORK/all.json" '
  (.[] | select(.kind == "Deployment" and .metadata.name == "demo-tool") | .spec
    | (if (.replicas // 1) > 1 then "demo-tool replicas \(.replicas) > 1" else empty end),
      (if .strategy.type != "Recreate" then "demo-tool strategy 须为 Recreate" else empty end)),
  (.[] | select(.kind == "Deployment" and .metadata.name == "aster-guard-mcp") | .spec.template.spec.containers[0].args
    | (if (index(["--isolation"]) as $i | .[$i + 1]) != "network,auth" then "aster-guard-mcp 须 --isolation network,auth" else empty end),
      (if (index(["--listen"]) == null) then "aster-guard-mcp 须为 --listen 监听模式" else empty end))'

check "guard-auth-probe：Forbid、历史 1/3、单次 120 s、backoffLimit 0、不挂 Secret" jq_none "$WORK/all.json" '
  [.[] | select(.kind == "CronJob")] as $cj
  | (if ($cj | length) != 1 then "CronJob 数须为 1" else empty end),
    ($cj[] | .spec as $s
      | (if $s.concurrencyPolicy != "Forbid" then "concurrencyPolicy 须为 Forbid" else empty end),
        (if [$s.successfulJobsHistoryLimit, $s.failedJobsHistoryLimit] != [1, 3] then "历史限额须为 1 / 3" else empty end),
        (if $s.jobTemplate.spec.activeDeadlineSeconds != 120 then "activeDeadlineSeconds 须为 120" else empty end),
        (if $s.jobTemplate.spec.backoffLimit != 0 then "backoffLimit 须为 0（auth-status 要求每个 Job 恰一个 Pod）" else empty end),
        ($s.jobTemplate.spec.template.spec | .. | objects | select(has("secretKeyRef") or has("secretRef") or has("secret")) | "票据探针不得引用任何 Secret：\(tojson)"))'

# 探针 SA 权限表（计划 Task 7，唯一来源）：三个 Role 的规则与此表完全相等（规则顺序无关）。
EXPECTED_RULES='{
  "aster-agents/guard-bypass-probe": [
    {"apiGroups":[""],"resources":["pods"],"verbs":["create","delete","get","list","watch"]},
    {"apiGroups":[""],"resources":["pods/log"],"verbs":["get"]},
    {"apiGroups":["rbac.authorization.k8s.io"],"resources":["rolebindings"],"verbs":["list"]}],
  "aster-tools/guard-bypass-probe-read": [
    {"apiGroups":[""],"resources":["pods"],"verbs":["get","list"]},
    {"apiGroups":["networking.k8s.io"],"resources":["networkpolicies"],"verbs":["get","list"]},
    {"apiGroups":["apps"],"resources":["deployments"],"verbs":["get"]}],
  "aster-guard/guard-bypass-probe-read": [
    {"apiGroups":[""],"resources":["pods"],"verbs":["get","list"]},
    {"apiGroups":[""],"resources":["pods/log"],"verbs":["get"]},
    {"apiGroups":["batch"],"resources":["jobs"],"verbs":["get","list"]},
    {"apiGroups":["apps"],"resources":["deployments"],"verbs":["get"]}]
}'
check "探针 Role 规则与权限表完全相等" jq_none "$WORK/all.json" --argjson want "$EXPECTED_RULES" '
  def norm: map({apiGroups: (.apiGroups | sort), resources: (.resources | sort), verbs: (.verbs | sort)}) | sort;
  ([.[] | select(.kind == "Role")] | map({key: "\(.metadata.namespace)/\(.metadata.name)", value: (.rules | norm)}) | from_entries) as $got
  | ($want | map_values(norm)) as $w
  | (if ($got | keys) != ($w | keys) then "Role 集合不符：\($got | keys)" else empty end),
    ($w | to_entries[] | select($got[.key] != .value) | "\(.key) 规则不符：\($got[.key] | tojson)")'
check "探针 Role 不含 secrets、exec / attach / portforward / ephemeralcontainers、通配" jq_none "$WORK/all.json" '
  .[] | select(.kind == "Role" or .kind == "ClusterRole") | .metadata.name as $n | .rules[]
  | select((.resources | any(. == "secrets" or . == "pods/exec" or . == "pods/attach" or . == "pods/portforward" or . == "pods/ephemeralcontainers" or . == "*"))
      or (.verbs | any(. == "*")) or (.apiGroups | any(. == "*")))
  | "\($n)：越权规则 \(tojson)"'
check "RoleBinding 只绑定 aster-guard/guard-bypass-probe；aster-agents 内无指向本命名空间 SA 的绑定" jq_none "$WORK/all.json" '
  .[] | select(.kind == "RoleBinding") | .metadata as $m | .subjects[]
  | select(.kind != "ServiceAccount" or .name != "guard-bypass-probe" or .namespace != "aster-guard")
  | "\($m.namespace)/\($m.name)：意外的 subject \(tojson)"'

# pods/create 等于间接读取 aster-agents 的全部 Secret：该命名空间可产生 Secret 的对象恰为 ExternalSecret guard-demo-agent（Opaque）。
check "aster-agents 唯一的 Secret 来源是 ExternalSecret guard-demo-agent" jq_none "$WORK/agents.json" '
  [.[] | select(.kind == "Secret" or .kind == "ExternalSecret" or .kind == "SealedSecret" or .kind == "PushSecret")] as $s
  | (if ($s | map("\(.kind)/\(.metadata.name)")) != ["ExternalSecret/guard-demo-agent"] then "可产生 Secret 的对象不符：\($s | map("\(.kind)/\(.metadata.name)"))" else empty end),
    ($s[] | select(.kind == "ExternalSecret") | .spec.target
      | select(.name != "guard-demo-agent" or (.template.type // "Opaque") != "Opaque") | "ExternalSecret 目标须为 Opaque Secret guard-demo-agent：\(tojson)")'
check "aster-agents 没有工作负载（只有探针临时 Pod）" jq_none "$WORK/agents.json" '
  .[] | select(.kind | IN("Deployment","StatefulSet","DaemonSet","Job","CronJob","Pod","ServiceAccount")) | "aster-agents 不得放 \(.kind)/\(.metadata.name)"'
check "aster-agents 配额：pods 4、limits 1 CPU / 1 Gi" jq_none "$WORK/agents.json" '
  [.[] | select(.kind == "ResourceQuota")][0].spec.hard as $h
  | if $h == null or $h.pods != "4" or $h["limits.cpu"] != "1" or $h["limits.memory"] != "1Gi" then "ResourceQuota 不符：\($h)" else empty end'

if [[ "$FAILED" != 0 ]]; then
  echo "manifests.test.sh：有断言失败" >&2
  exit 1
fi
echo "manifests.test.sh：全部通过"
