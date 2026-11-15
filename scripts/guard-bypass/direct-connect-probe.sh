#!/usr/bin/env bash
# 部署层直连探针（aster-api ADR 0054 §12 D7 / D9；wontlost-ltd/aster-api#466 第 1 条）。
#
# 子命令：
#   network      证明「模型命名空间直连原始工具」被网络层挡住：
#                静态核对工具入站策略并集、aster-agents 无 SA 绑定、工具 Deployment 形状；
#                再在 <agents-ns> 起两个一次性 Pod（same：与工具 Pod 同节点；cross：反亲和到其它节点），
#                各自对 Service DNS 与 Pod IP 两个目标发 POST /mcp。附正向对照（同一 Pod 能访问代理）与金丝雀
#                （持有效 Agent token 经代理调 demo_echo 成功、demo_delete 被拒），证明「挡住」不是「坏了」。
#   auth-status  读取 <since> 之后由票据层 CronJob 创建的 Job 的摘要（auth-probe.sh 的末行 JSON）。
#
# 退出码：0 通过；1 绕过成功（直连可达 / 静态形状违规）；2 参数错误；3 无法判定（DNS、调度、正向对照、
#         金丝雀、超时等——工作流对 1 与 3 都判红）。最后一行恒为 JSON 摘要。
#
# 所需权限恰为 apps/aster-lang/{agents,guard,tools} 中 guard-bypass-probe 的 Role（计划 Task 7 权限表）：
# 出现表外 kubectl 调用即为缺陷，应改本脚本而不是扩权限。
#
# 可调参数（测试用）：PROBE_POLL_SECONDS（缺省 3）、PROBE_POD_TIMEOUT（缺省 95）、AUTH_POLL_SECONDS（缺省 15）、
#                    PROBE_NOW_EPOCH（缺省当前时间）、KUBECTL（缺省 kubectl）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/guard-bypass/lib.sh
source "$HERE/lib.sh"

KUBECTL="${KUBECTL:-kubectl}"
POLL="${PROBE_POLL_SECONDS:-3}"
POD_TIMEOUT="${PROBE_POD_TIMEOUT:-95}"
AUTH_POLL="${AUTH_POLL_SECONDS:-15}"
PROBE_LABEL="app.kubernetes.io/name=guard-bypass-probe"
STALE_SECONDS=600

usage() {
  cat >&2 <<'USAGE'
用法：
  direct-connect-probe.sh network --agents-ns <ns> --tool-ns <ns> --tool-selector <k=v> --tool-svc <name:port>
                                  --admit-ns <ns> --probe-image <ref@sha256:…> [--positive-url <url>]
                                  [--canary-proxy <url> --canary-secret <name>] [--run-id <id>] [--dry-run]
  direct-connect-probe.sh auth-status --guard-ns <ns> --cronjob <name> --since <RFC3339> [--wait <seconds>]
USAGE
  exit 2
}

now_epoch() { echo "${PROBE_NOW_EPOCH:-$(date -u +%s)}"; }

# summary <verdict> <exit> <json 片段对象>：打印末行摘要并以对应退出码结束。
finish() {
  local verdict="$1" code="$2" extra="$3"
  jq -cn --arg v "$verdict" --arg run "${RUN_ID:-}" --argjson extra "$extra" '{verdict: $v, runId: $run} + $extra'
  exit "$code"
}

# ───────────────────────────── network ─────────────────────────────

# 探针 Pod 内执行的脚本（busybox sh + curl）。每个目标一行 RESULT，正向对照一行 POSITIVE，金丝雀两行 CANARY。
# 正向对照用 curl -k：它只证明该 Pod 的 DNS 与出站可用（红队副本里指向 https://kubernetes.default.svc/livez，
# 而探针 Pod 不挂 SA token 也就没有集群 CA），TLS 身份与此无关；任何 HTTP 状态都算可达。
# 金丝雀判定依赖 aster-guard 的 JSON 序列化（JSON.stringify，无空白）：
#   echo   成功 ⇔ 无 "isError":true 且 _meta.asterGuard 以 {"decisionId":"<uuid>","attemptId" 开头；
#   delete 被拒 ⇔ "isError":true 且 asterGuard 以 {"status":"denied" 开头。
# shellcheck disable=SC2016  # 单引号内的 $ 由 Pod 内的 sh 展开
POD_SCRIPT='
for t in $TARGETS; do
  code=$(curl -sS -o /dev/null -m 5 -w "%{http_code}" -X POST "$t" 2>/dev/null); rc=$?
  echo "RESULT $t $rc ${code:-000}"
done
if [ -n "${POSITIVE_URL:-}" ]; then
  code=$(curl -k -sS -o /dev/null -m 5 -w "%{http_code}" "$POSITIVE_URL" 2>/dev/null); rc=$?
  echo "POSITIVE $rc ${code:-000}"
fi
if [ -n "${CANARY_URL:-}" ]; then
  call() {
    curl -sS -m 20 -X POST -H "Authorization: Bearer $CANARY_TOKEN" -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" --data "$1" "$CANARY_URL" 2>/dev/null
  }
  echo_body=$(call "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"demo_echo\",\"arguments\":{\"message\":\"probe-$RUN_ID\"}}}")
  if echo "$echo_body" | grep -q "\"isError\":true"; then e=fail
  elif echo "$echo_body" | grep -Eq "\"asterGuard\":\\{\"decisionId\":\"[0-9a-f-]{36}\",\"attemptId\""; then e=ok
  else e=fail; fi
  echo "CANARY echo $e"
  del_body=$(call "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"demo_delete\",\"arguments\":{\"id\":\"probe-$RUN_ID\"}}}")
  if echo "$del_body" | grep -q "\"isError\":true" && echo "$del_body" | grep -q "\"asterGuard\":{\"status\":\"denied\""; then d=ok
  else d=fail; fi
  echo "CANARY delete $d"
fi
echo "DONE"
'

# probe_pod_json <path: same|cross> <tool-node>：输出一个探针 Pod 的 JSON（满足 PSA restricted 与准入策略 guard-probe-pod-scope）。
probe_pod_json() {
  local path="$1" node="$2" targets="$3"
  jq -n \
    --arg name "guard-bypass-probe-${RUN_ID}-${path}" --arg ns "$AGENTS_NS" --arg run "$RUN_ID" --arg path "$path" \
    --arg image "$PROBE_IMAGE" --arg script "$POD_SCRIPT" --arg targets "$targets" --arg node "$node" \
    --arg toolNs "$TOOL_NS" --arg selKey "${TOOL_SELECTOR%%=*}" --arg selVal "${TOOL_SELECTOR#*=}" \
    --arg positive "${POSITIVE_URL:-}" --arg canary "$( [[ "$path" == cross ]] && echo "${CANARY_PROXY:-}" )" \
    --arg secret "${CANARY_SECRET:-}" '
    {
      apiVersion: "v1", kind: "Pod",
      metadata: {
        name: $name, namespace: $ns,
        labels: {"app.kubernetes.io/name": "guard-bypass-probe", "guard-bypass/run-id": $run, "guard-bypass/path": $path}
      },
      spec: ({
        restartPolicy: "Never",
        activeDeadlineSeconds: 90,
        automountServiceAccountToken: false,
        enableServiceLinks: false,
        securityContext: {runAsNonRoot: true, runAsUser: 100, runAsGroup: 101, seccompProfile: {type: "RuntimeDefault"}},
        containers: [{
          name: "probe", image: $image,
          command: ["sh", "-c", $script],
          env: ([
            {name: "TARGETS", value: $targets},
            {name: "RUN_ID", value: $run},
            {name: "POSITIVE_URL", value: $positive}
          ] + (if $canary == "" then [] else [
            {name: "CANARY_URL", value: $canary},
            {name: "CANARY_TOKEN", valueFrom: {secretKeyRef: {name: $secret, key: "token"}}}
          ] end)),
          resources: {requests: {cpu: "10m", memory: "16Mi"}, limits: {cpu: "100m", memory: "32Mi"}},
          securityContext: {
            allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, runAsNonRoot: true,
            capabilities: {drop: ["ALL"]}
          }
        }]
      } + (if $path == "same" then {nodeSelector: {"kubernetes.io/hostname": $node}} else {
        affinity: {podAntiAffinity: {requiredDuringSchedulingIgnoredDuringExecution: [{
          labelSelector: {matchLabels: {($selKey): $selVal}},
          namespaces: [$toolNs],
          topologyKey: "kubernetes.io/hostname"
        }]}}
      } end))
    }'
}

# shellcheck disable=SC2329  # 由 trap 调用
cleanup_run() {
  [[ -n "${RUN_ID:-}" && "${DRY_RUN:-0}" != 1 && "${CREATED:-0}" == 1 ]] || return 0
  "$KUBECTL" delete pod -n "$AGENTS_NS" -l "guard-bypass/run-id=$RUN_ID" --wait=false >/dev/null 2>&1 || true
}

network() {
  AGENTS_NS="" TOOL_NS="" TOOL_SELECTOR="" TOOL_SVC="" ADMIT_NS="" PROBE_IMAGE="" POSITIVE_URL="" CANARY_PROXY="" CANARY_SECRET=""
  RUN_ID="" DRY_RUN=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agents-ns) AGENTS_NS="${2:-}"; shift 2 ;;
      --tool-ns) TOOL_NS="${2:-}"; shift 2 ;;
      --tool-selector) TOOL_SELECTOR="${2:-}"; shift 2 ;;
      --tool-svc) TOOL_SVC="${2:-}"; shift 2 ;;
      --admit-ns) ADMIT_NS="${2:-}"; shift 2 ;;
      --probe-image) PROBE_IMAGE="${2:-}"; shift 2 ;;
      --positive-url) POSITIVE_URL="${2:-}"; shift 2 ;;
      --canary-proxy) CANARY_PROXY="${2:-}"; shift 2 ;;
      --canary-secret) CANARY_SECRET="${2:-}"; shift 2 ;;
      --run-id) RUN_ID="${2:-}"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      *) echo "未知参数：$1" >&2; usage ;;
    esac
  done
  [[ -n "$AGENTS_NS" && -n "$TOOL_NS" && -n "$TOOL_SELECTOR" && -n "$TOOL_SVC" && -n "$ADMIT_NS" && -n "$PROBE_IMAGE" ]] || usage
  [[ "$TOOL_SELECTOR" =~ ^[A-Za-z0-9./_-]+=[A-Za-z0-9._-]+$ ]] || { echo "--tool-selector 须为 k=v" >&2; usage; }
  [[ "$TOOL_SVC" =~ ^[a-z0-9-]+:[0-9]+$ ]] || { echo "--tool-svc 须为 name:port" >&2; usage; }
  [[ "$PROBE_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || { echo "--probe-image 须按 @sha256 固定" >&2; usage; }
  [[ -z "$CANARY_PROXY" || -n "$CANARY_SECRET" ]] || { echo "--canary-proxy 需要 --canary-secret" >&2; usage; }
  RUN_ID="${RUN_ID:-local-$(now_epoch)}"
  [[ "$RUN_ID" =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]] || { echo "--run-id 须为 ≤40 字符的小写字母数字与 -" >&2; usage; }
  local svc_name="${TOOL_SVC%%:*}" port="${TOOL_SVC##*:}"
  local tmp; tmp="$(mktemp -d)"
  CREATED=0
  trap 'cleanup_run; rm -rf "$tmp"' EXIT
  trap 'exit 3' INT TERM

  # ── 1. 静态核对 ──
  local reasons=()
  "$KUBECTL" get networkpolicy -n "$TOOL_NS" -o json >"$tmp/policies.json" || finish inconclusive 3 '{"reasons":["无法读取工具命名空间的 NetworkPolicy"]}'
  "$KUBECTL" get pods -n "$TOOL_NS" -l "$TOOL_SELECTOR" -o json >"$tmp/tool-pods.json" || finish inconclusive 3 '{"reasons":["无法读取工具 Pod"]}'
  local running
  running="$(jq '[.items[] | select(.status.phase == "Running" and .metadata.deletionTimestamp == null)] | length' "$tmp/tool-pods.json")"
  [[ "$running" == 1 ]] || finish inconclusive 3 "$(jq -cn --arg n "$running" '{reasons: ["工具 Pod 运行中的数量须恰为 1，实为 \($n)"]}')"
  jq '[.items[] | select(.status.phase == "Running")][0]' "$tmp/tool-pods.json" >"$tmp/tool-pod.json"
  jq '.metadata.labels // {}' "$tmp/tool-pod.json" >"$tmp/labels.json"
  local tool_ip tool_node
  tool_ip="$(jq -r '.status.podIP // ""' "$tmp/tool-pod.json")"
  tool_node="$(jq -r '.spec.nodeName // ""' "$tmp/tool-pod.json")"
  [[ -n "$tool_ip" && -n "$tool_node" ]] || finish inconclusive 3 '{"reasons":["工具 Pod 缺 podIP 或 nodeName"]}'

  while IFS= read -r v; do [[ -n "$v" ]] && reasons+=("$v"); done < <(policy_union_violations "$tmp/policies.json" "$tmp/labels.json" "$ADMIT_NS")

  "$KUBECTL" get rolebindings -n "$AGENTS_NS" -o json >"$tmp/rb.json" || finish inconclusive 3 '{"reasons":["无法列出模型命名空间的 RoleBinding"]}'
  while IFS= read -r v; do [[ -n "$v" ]] && reasons+=("$v"); done < <(jq -r --arg ns "$AGENTS_NS" '
    .items[] | .metadata.name as $rb | (.subjects // [])[]
    | select(.kind == "ServiceAccount" and (.namespace // $ns) == $ns)
    | "agents_sa_binding \($rb): 模型命名空间内的 RoleBinding 指向本命名空间的 ServiceAccount \(.name)"' "$tmp/rb.json")

  "$KUBECTL" get deployment -n "$TOOL_NS" "$svc_name" -o json >"$tmp/deploy.json" || finish inconclusive 3 '{"reasons":["无法读取工具 Deployment"]}'
  while IFS= read -r v; do [[ -n "$v" ]] && reasons+=("$v"); done < <(jq -r '
    (if .spec.replicas != 1 then "tool_replicas: 工具 Deployment replicas 须为 1（进程内票据账本），实为 \(.spec.replicas)" else empty end),
    (if (.spec.strategy.type // "RollingUpdate") != "Recreate" then "tool_strategy: 工具 Deployment 须 strategy Recreate" else empty end),
    ([.spec.template.spec.containers[], (.spec.template.spec.initContainers // [])[]] | .[] | (.env // [])[]
      | select(.name == "TICKET_CHECK" and .value == "off") | "ticket_check_off: 工具容器设置了 TICKET_CHECK=off")' "$tmp/deploy.json")

  if [[ ${#reasons[@]} -gt 0 ]]; then
    finish bypass 1 "$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -cs '{reasons: .}')"
  fi

  # ── 2. 清扫残留探针 Pod（> 600 s）──
  local targets="http://${svc_name}.${TOOL_NS}.svc.cluster.local:${port}/mcp http://${tool_ip}:${port}/mcp"
  probe_pod_json same "$tool_node" "$targets" >"$tmp/same.json"
  probe_pod_json cross "$tool_node" "$targets" >"$tmp/cross.json"
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "# dry-run：以下 Pod 不会创建（真实运行会先清扫 ${AGENTS_NS} 中超过 ${STALE_SECONDS}s 的探针 Pod）" >&2
    jq . "$tmp/same.json" "$tmp/cross.json" >&2
    finish dry-run 0 "$(jq -cn --arg t "$targets" '{targets: ($t | split(" "))}')"
  fi
  "$KUBECTL" get pods -n "$AGENTS_NS" -l "$PROBE_LABEL" -o json >"$tmp/old.json" || finish inconclusive 3 '{"reasons":["无法列出残留探针 Pod"]}'
  local stale
  stale="$(jq -r --argjson now "$(now_epoch)" --argjson age "$STALE_SECONDS" \
    '.items[] | select(($now - (.metadata.creationTimestamp | fromdateiso8601)) > $age) | .metadata.name' "$tmp/old.json")"
  if [[ -n "$stale" ]]; then
    # shellcheck disable=SC2086  # 名称按行拆为多个参数
    "$KUBECTL" delete pod -n "$AGENTS_NS" $stale --wait=false >/dev/null || true
  fi

  # ── 3. 起两个探针 Pod ──
  CREATED=1
  "$KUBECTL" create -f - <"$tmp/same.json" >/dev/null || finish inconclusive 3 '{"reasons":["创建 same 探针 Pod 失败（PSA / 准入 / 配额？）"]}'
  "$KUBECTL" create -f - <"$tmp/cross.json" >/dev/null || finish inconclusive 3 '{"reasons":["创建 cross 探针 Pod 失败（PSA / 准入 / 配额？）"]}'

  # ── 4. 等两个 Pod 结束 ──
  local deadline=$(( $(date +%s) + POD_TIMEOUT )) phases=""
  while :; do
    # 查询失败不当作任何状态：记为 query-failed 继续等，到时限即判 3（不会沿用旧输出——重定向先截断文件）。
    if "$KUBECTL" get pods -n "$AGENTS_NS" -l "guard-bypass/run-id=$RUN_ID" -o json >"$tmp/run.json" 2>/dev/null; then
      phases="$(jq -r '[.items[] | .status.phase // "Unknown"] | sort | join(",")' "$tmp/run.json" 2>/dev/null || echo "unparseable")"
    else
      phases="query-failed"
    fi
    [[ "$phases" == "Succeeded,Succeeded" ]] && break
    if [[ "$phases" == *Failed* || $(date +%s) -ge $deadline ]]; then
      finish inconclusive 3 "$(jq -cn --arg p "$phases" '{reasons: ["探针 Pod 未在时限内成功结束（phases=\($p)）：调度失败、准入拒绝或镜像拉取失败"]}')"
    fi
    sleep "$POLL"
  done

  # ── 5. 读结果并判定 ──
  local results=() inconclusive=() bypass=() positive="" canary_echo="" canary_delete=""
  local path pod node log
  for path in same cross; do
    pod="guard-bypass-probe-${RUN_ID}-${path}"
    node="$(jq -r --arg p "$pod" '.items[] | select(.metadata.name == $p) | .spec.nodeName // ""' "$tmp/run.json")"
    if [[ "$path" == same && "$node" != "$tool_node" ]]; then inconclusive+=("same Pod 不在工具节点 ${tool_node}（实为 ${node}）"); fi
    if [[ "$path" == cross && "$node" == "$tool_node" ]]; then inconclusive+=("cross Pod 落在工具节点 ${tool_node}，跨节点路径未覆盖"); fi
    log="$("$KUBECTL" logs -n "$AGENTS_NS" "$pod" 2>/dev/null)" || { inconclusive+=("无法读取 ${pod} 日志"); continue; }
    grep -q '^DONE$' <<<"$log" || inconclusive+=("${pod} 日志不完整")
    local n=0 target rc code class seen=""
    while read -r _ target rc code; do
      n=$((n + 1))
      seen="${seen}${target} "
      # 行格式异常（非数字退出码 / 状态码）一律无法判定，不交给 classify_curl。
      if ! [[ "$rc" =~ ^[0-9]+$ && "$code" =~ ^[0-9]{3}$ ]]; then
        inconclusive+=("${pod} 的 RESULT 行格式异常：${target} ${rc} ${code}")
        continue
      fi
      class="$(classify_curl "$rc" "$code")"
      results+=("$(jq -cn --arg pod "$path" --arg node "$node" --arg t "$target" --arg rc "$rc" --arg code "$code" --arg c "$class" \
        '{path: $pod, node: $node, target: $t, curlExit: ($rc | tonumber), httpCode: $code, class: $c}')")
      [[ "$class" == reachable ]] && bypass+=("${path} → ${target} 可达（curl ${rc}，HTTP ${code}）")
      [[ "$class" == inconclusive ]] && inconclusive+=("${path} → ${target} 无法判定（curl ${rc}）")
    done < <(grep '^RESULT ' <<<"$log" || true)
    [[ "$n" == 2 ]] || inconclusive+=("${pod} 的 RESULT 行数须为 2，实为 ${n}")
    # 两个目标必须恰好各出现一次（防止重复行或目标被替换后仍凑足两行）。
    [[ "$(tr ' ' '\n' <<<"$seen" | sed '/^$/d' | sort | tr '\n' ' ')" == "$(tr ' ' '\n' <<<"$targets" | sort | tr '\n' ' ')" ]] ||
      inconclusive+=("${pod} 的 RESULT 目标与期望不符：${seen}")
    if [[ -n "$POSITIVE_URL" ]]; then
      local prc pcode
      read -r _ prc pcode < <(grep '^POSITIVE ' <<<"$log" || echo "POSITIVE missing 000")
      positive="${positive}${path}:$(classify_curl "$prc" "$pcode") "
      [[ "$(classify_curl "$prc" "$pcode")" == reachable ]] || inconclusive+=("${path} 正向对照失败（curl ${prc}）：该 Pod 的 DNS / 出站本身不通")
    fi
    if [[ "$path" == cross && -n "$CANARY_PROXY" ]]; then
      canary_echo="$(sed -n 's/^CANARY echo //p' <<<"$log")"
      canary_delete="$(sed -n 's/^CANARY delete //p' <<<"$log")"
      [[ "$canary_echo" == ok ]] || inconclusive+=("金丝雀 demo_echo 经代理未成功：代理或链路故障")
      [[ "$canary_delete" == ok ]] || inconclusive+=("金丝雀 demo_delete 未被 DENY：策略或代理故障")
    fi
  done

  local extra
  extra="$(jq -cn \
    --argjson results "$(printf '%s\n' "${results[@]}" | jq -cs .)" \
    --argjson bypass "$(printf '%s\n' "${bypass[@]+"${bypass[@]}"}" | jq -R 'select(. != "")' | jq -cs .)" \
    --argjson inc "$(printf '%s\n' "${inconclusive[@]+"${inconclusive[@]}"}" | jq -R 'select(. != "")' | jq -cs .)" \
    --arg toolNode "$tool_node" --arg positive "$positive" --arg ce "$canary_echo" --arg cd "$canary_delete" \
    '{toolNode: $toolNode, results: $results, positive: $positive, canary: {echo: $ce, delete: $cd}, reasons: ($bypass + $inc)}')"
  if [[ ${#bypass[@]} -gt 0 ]]; then finish bypass 1 "$extra"; fi
  if [[ ${#inconclusive[@]} -gt 0 ]]; then finish inconclusive 3 "$extra"; fi
  finish pass 0 "$extra"
}

# ───────────────────────────── auth-status ─────────────────────────────

auth_status() {
  local guard_ns="" cronjob="" since="" wait=1500
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --guard-ns) guard_ns="${2:-}"; shift 2 ;;
      --cronjob) cronjob="${2:-}"; shift 2 ;;
      --since) since="${2:-}"; shift 2 ;;
      --wait) wait="${2:-}"; shift 2 ;;
      *) echo "未知参数：$1" >&2; usage ;;
    esac
  done
  [[ -n "$guard_ns" && -n "$cronjob" && "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ && "$wait" =~ ^[0-9]+$ ]] || usage
  local deadline=$(( $(date +%s) + wait )) job="" done_="" tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  while :; do
    if "$KUBECTL" get jobs -n "$guard_ns" -o json >"$tmp/jobs.json" 2>/dev/null; then
      # 收敛时刻之后启动、由该 CronJob 创建的最早一个 Job（轮询而非 watch：权限表只给 get / list）。
      read -r job done_ < <(jq -r --arg cj "$cronjob" --arg since "$since" '
        [.items[] | select((.metadata.ownerReferences // [])[0].name == $cj and (.status.startTime // "") >= $since)]
        | sort_by(.status.startTime) | .[0] // empty
        | "\(.metadata.name) \(if ((.status.conditions // []) | any(.type == "Complete" or .type == "Failed")) and (.status.active // 0) == 0 then "done" else "running" end)"' \
        "$tmp/jobs.json") || true
      [[ -n "$job" && "$done_" == "done" ]] && break
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      finish inconclusive 3 "$(jq -cn --arg cj "$cronjob" --arg s "$since" --arg j "$job" '{reasons: ["等待超时：\($s) 之后没有已结束的 \($cj) Job（当前：\($j)）"]}')"
    fi
    sleep "$AUTH_POLL"
  done
  local pod line
  "$KUBECTL" get pods -n "$guard_ns" -l "job-name=$job" -o json >"$tmp/pods.json" 2>/dev/null ||
    finish inconclusive 3 "$(jq -cn --arg j "$job" '{reasons: ["无法列出 Job \($j) 的 Pod"]}')"
  # CronJob 的 backoffLimit 为 0：每个 Job 恰一个 Pod。
  pod="$(jq -r 'if (.items | length) == 1 then .items[0].metadata.name else "" end' "$tmp/pods.json")"
  [[ -n "$pod" ]] || finish inconclusive 3 "$(jq -cn --arg j "$job" '{reasons: ["Job \($j) 的 Pod 数须恰为 1"]}')"
  line="$("$KUBECTL" logs -n "$guard_ns" "$pod" 2>/dev/null | tail -n1)" || true
  local verdict
  verdict="$(jq -r '.verdict // ""' <<<"$line" 2>/dev/null || true)"
  local extra
  extra="$(jq -cn --arg j "$job" --arg l "$line" '{job: $j, summary: ($l | fromjson? // $l)}')"
  case "$verdict" in
    pass) finish pass 0 "$extra" ;;
    bypass) finish bypass 1 "$extra" ;;
    *) finish inconclusive 3 "$extra" ;;
  esac
}

case "${1:-}" in
  network) shift; network "$@" ;;
  auth-status) shift; auth_status "$@" ;;
  *) usage ;;
esac
