#!/usr/bin/env bash
# 准入策略 guard-agents-secret-allowlist / guard-probe-pod-scope 的行为核对（aster-api ADR 0054 §12 D9；计划 Task 7c Step 4）。
#
# 由用户以**管理员** kubeconfig 运行（发放探针凭证 U-K6 之前的硬门）；探针身份用 --as 模拟，所以不需要先发放探针凭证。
# 表驱动：每条准入分支至少一个服务端 dry-run 用例，逐条打印期望与实际，任一不符退出 1。用例清单就是验收标准，
# 增删规则须同步增删用例。D1 / D2 / R1 需要真实对象：先以管理员建带标签与无标签的 pause Pod 各一个，核对后删除。
#
# 用法：bash scripts/guard-bypass/vap-check.sh [--kubeconfig <path>]
# 期望：deny-vap = 被该准入策略拒绝（错误信息含策略名）；deny = 被拒（任何准入或校验）；forbidden = RBAC 403；
#       allow = 未被拒；not-vap = 成功或 AlreadyExists，且错误信息不含策略名。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/guard-bypass/direct-connect-probe.sh
source "$HERE/direct-connect-probe.sh"

KC=()
if [[ "${1:-}" == "--kubeconfig" ]]; then KC=(--kubeconfig "${2:?--kubeconfig 需要路径}"); fi
K() { kubectl "${KC[@]+"${KC[@]}"}" "$@"; }
AS=(--as=system:serviceaccount:aster-guard:guard-bypass-probe)
NS=aster-agents
PAUSE="registry.k8s.io/pause:3.10@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a"
FAILED=0
RUN="vapcheck$(date +%s)"

# 「合法探针 Pod」：与 direct-connect-probe.sh 生成的 cross Pod 同一函数（含 secretKeyRef guard-demo-agent），
# 另加 emptyDir 与 configMap 卷（P1 要覆盖三种允许的卷）。
AGENTS_NS=$NS TOOL_NS=aster-tools TOOL_SELECTOR=app=demo-tool RUN_ID=$RUN
PROBE_IMAGE="docker.io/curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"
POSITIVE_URL="" CANARY_PROXY="http://aster-guard-mcp.aster-guard.svc.cluster.local:8080/mcp" CANARY_SECRET=guard-demo-agent
BASE="$(probe_pod_json cross unused "http://x/mcp" | jq '
  .metadata.name = "vap-check-pod"
  | .spec.volumes = [{name: "tmp", emptyDir: {}}, {name: "cfg", configMap: {name: "kube-root-ca.crt"}}]
  | .spec.containers[0].volumeMounts = [{name: "tmp", mountPath: "/tmp"}, {name: "cfg", mountPath: "/cfg"}]')"

# case_ <编号> <期望> <身份 admin|probe> <说明> <jq 改动>：以 BASE 改动一处后服务端 dry-run 创建 Pod。
case_() {
  local id="$1" want="$2" who="$3" desc="$4" patch="$5"
  local out code=0
  local as=()
  [[ "$who" == probe ]] && as=("${AS[@]}")
  out="$(jq "$patch" <<<"$BASE" | K create -f - --dry-run=server "${as[@]+"${as[@]}"}" -o name 2>&1)" || code=$?
  judge "$id" "$want" "$desc" "$code" "$out" guard-probe-pod-scope
}

# judge <编号> <期望> <说明> <退出码> <输出> <策略名>
judge() {
  local id="$1" want="$2" desc="$3" code="$4" out="$5" policy="$6" got
  if [[ "$code" == 0 ]]; then got=allow
  elif grep -q "ValidatingAdmissionPolicy '$policy'" <<<"$out"; then got=deny-vap
  elif grep -qi "forbidden" <<<"$out" && grep -qi "cannot" <<<"$out"; then got=forbidden
  elif grep -q "AlreadyExists\|already exists" <<<"$out"; then got=exists
  else got=deny; fi
  local ok=0
  case "$want" in
    deny) [[ "$got" == deny || "$got" == deny-vap ]] && ok=1 ;;
    not-vap) [[ "$got" == allow || "$got" == exists ]] && ok=1 ;;
    *) [[ "$got" == "$want" ]] && ok=1 ;;
  esac
  if [[ "$ok" == 1 ]]; then
    printf '  ✓ %-4s 期望 %-9s 实际 %-9s %s\n' "$id" "$want" "$got" "$desc"
  else
    printf '  ✗ %-4s 期望 %-9s 实际 %-9s %s\n      %s\n' "$id" "$want" "$got" "$desc" "$(head -c 300 <<<"$out")"
    FAILED=1
  fi
}

secret_case() {
  local id="$1" want="$2" desc="$3"; shift 3
  local out code=0
  out="$(K create secret "$@" -n "$NS" --dry-run=server -o name 2>&1)" || code=$?
  judge "$id" "$want" "$desc" "$code" "$out" guard-agents-secret-allowlist
}

echo "== Secret 白名单（guard-agents-secret-allowlist）"
secret_case S1 deny-vap "管理员建 Opaque Secret x" generic x --from-literal=k=v
# S2 用白名单内的名字，只改 type，确认 type 规则独立生效；带上 SA 注解以先通过字段校验（否则不会走到准入）。
code=0
out="$(jq -n '{apiVersion: "v1", kind: "Secret", type: "kubernetes.io/service-account-token",
  metadata: {name: "guard-demo-agent", namespace: "aster-agents", annotations: {"kubernetes.io/service-account.name": "default"}}}' |
  K create -f - --dry-run=server -o name 2>&1)" || code=$?
judge S2 deny-vap "管理员建 service-account-token 类型的 guard-demo-agent" "$code" "$out" guard-agents-secret-allowlist
secret_case S3 not-vap "管理员建 Opaque guard-demo-agent（成功或 AlreadyExists）" generic guard-demo-agent --from-literal=k=v

echo "== 探针 Pod 形状（guard-probe-pod-scope）"
case_ P1  allow    probe "合法探针 Pod（secretKeyRef guard-demo-agent、emptyDir、configMap 卷）" '.'
case_ P1b allow    probe "合法探针 Pod 变体：无卷、无 env" 'del(.spec.volumes) | del(.spec.containers[0].volumeMounts) | del(.spec.containers[0].env)'
case_ P2a deny-vap probe "缺 app.kubernetes.io/name 标签" 'del(.metadata.labels["app.kubernetes.io/name"])'
case_ P2b deny-vap probe "缺 guard-bypass/run-id 标签" 'del(.metadata.labels["guard-bypass/run-id"])'
case_ P3  deny     probe "serviceAccountName: other" '.spec.serviceAccountName = "other"'
case_ P4a deny-vap probe "automountServiceAccountToken 缺省" 'del(.spec.automountServiceAccountToken)'
case_ P4b deny-vap probe "automountServiceAccountToken: true" '.spec.automountServiceAccountToken = true'
case_ P5a deny-vap probe "projected 卷（serviceAccountToken 源）" '.spec.volumes += [{name: "p", projected: {sources: [{serviceAccountToken: {path: "t"}}]}}]'
case_ P5b deny-vap probe "projected 卷（secret 源）" '.spec.volumes += [{name: "p", projected: {sources: [{secret: {name: "guard-demo-agent"}}]}}]'
case_ P6a deny-vap probe "secret 卷 secretName: other" '.spec.volumes += [{name: "s", secret: {secretName: "other"}}]'
case_ P6b allow    probe "secret 卷 secretName: guard-demo-agent" '.spec.volumes += [{name: "s", secret: {secretName: "guard-demo-agent"}}]'
case_ P7a deny     probe "hostPath 卷（PSA restricted 也会拒）" '.spec.volumes += [{name: "h", hostPath: {path: "/etc"}}]'
case_ P7b deny-vap probe "persistentVolumeClaim 卷" '.spec.volumes += [{name: "c", persistentVolumeClaim: {claimName: "x"}}]'
case_ P7c deny-vap probe "ephemeral 卷" '.spec.volumes += [{name: "e", ephemeral: {volumeClaimTemplate: {spec: {accessModes: ["ReadWriteOnce"], resources: {requests: {storage: "1Mi"}}}}}}]'
case_ P7d deny     probe "csi 卷（PSA restricted 也可能拒）" '.spec.volumes += [{name: "i", csi: {driver: "x.example.com"}}]'
case_ P8a deny-vap probe "containers[0] env secretKeyRef other" '.spec.containers[0].env += [{name: "X", valueFrom: {secretKeyRef: {name: "other", key: "k"}}}]'
case_ P8b deny-vap probe "initContainers[0] env secretKeyRef other" '.spec.initContainers = [.spec.containers[0] | .name = "init" | .env = [{name: "X", valueFrom: {secretKeyRef: {name: "other", key: "k"}}}]]'
case_ P9a deny-vap probe "containers[0] envFrom secretRef other" '.spec.containers[0].envFrom = [{secretRef: {name: "other"}}]'
case_ P9b deny-vap probe "initContainers[0] envFrom secretRef other" '.spec.initContainers = [.spec.containers[0] | .name = "init" | del(.env) | .envFrom = [{secretRef: {name: "other"}}]]'
case_ P11 allow    admin "管理员建 P8 同形 Pod（策略只匹配探针身份）" '.spec.containers[0].env += [{name: "X", valueFrom: {secretKeyRef: {name: "other", key: "k"}}}]'

echo "== 需要真实对象的用例（管理员建两个 pause Pod，核对后删除）"
pause_pod() {
  jq -n --arg name "$1" --arg image "$PAUSE" --argjson labels "$2" '{
    apiVersion: "v1", kind: "Pod", metadata: {name: $name, namespace: "aster-agents", labels: $labels},
    spec: {automountServiceAccountToken: false, restartPolicy: "Never", activeDeadlineSeconds: 300,
      securityContext: {runAsNonRoot: true, runAsUser: 65535, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{name: "pause", image: $image, resources: {requests: {cpu: "10m", memory: "8Mi"}, limits: {cpu: "10m", memory: "16Mi"}},
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}}]}}'
}
LABELED="vap-check-labeled-$RUN" PLAIN="vap-check-plain-$RUN"
trap 'K delete pod -n "$NS" "$LABELED" "$PLAIN" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
pause_pod "$LABELED" "{\"app.kubernetes.io/name\":\"guard-bypass-probe\",\"guard-bypass/run-id\":\"$RUN\"}" | K create -f - -o name >/dev/null
pause_pod "$PLAIN" '{}' | K create -f - -o name >/dev/null

code=0; out="$(K delete pod -n "$NS" "$LABELED" --dry-run=server "${AS[@]}" 2>&1)" || code=$?
judge D1 allow "探针身份删除带探针标签的 Pod" "$code" "$out" guard-probe-pod-scope
code=0; out="$(K delete pod -n "$NS" "$PLAIN" --dry-run=server "${AS[@]}" 2>&1)" || code=$?
judge D2 deny-vap "探针身份删除无标签 Pod" "$code" "$out" guard-probe-pod-scope
code=0
out="$(K patch pod -n "$NS" "$LABELED" --subresource=ephemeralcontainers --type=json --dry-run=server "${AS[@]}" \
  -p '[{"op":"add","path":"/spec/ephemeralContainers","value":[{"name":"dbg","image":"'"$PAUSE"'"}]}]' 2>&1)" || code=$?
judge R1 forbidden "探针身份追加 ephemeralContainers（RBAC 无该子资源）" "$code" "$out" guard-probe-pod-scope

if [[ "$FAILED" != 0 ]]; then
  echo "vap-check：有用例不符合期望——不得发放探针凭证（U-K6）" >&2
  exit 1
fi
echo "vap-check：全部用例符合期望"
