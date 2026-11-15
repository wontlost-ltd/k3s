#!/bin/sh
# 票据层探针（aster-api ADR 0054 §12 D7；wontlost-ltd/aster-api#466）。由 CronJob aster-guard/guard-auth-probe 运行：
# 该 Pod 位于被工具入站策略放行的 aster-guard 命名空间，与代理同等网络位置，但不持有任何票据或 Guard key。
# 证明「即使网络层放行，工具也拒绝无票据 / 伪造 / 畸形票据与批量请求，且没有副作用」。
#
# 运行环境：curlimages/curl（busybox sh + curl，无 jq）；只读根文件系统，不写文件。
# 输入：TOOL_URL（如 http://demo-tool.aster-tools.svc.cluster.local:8080）。
# ★所有步骤都执行、不提前退出（唯一例外：tools/list 不通）——关闭票据核对时也必须真的发出无票据调用并观察副作用，
#   反向记录 R-A 依赖这一点（只看 /healthz 的 ticketCheck 不足以证明无票据调用会执行）。
# 退出码：0 通过；1 绕过（④–⑦ 任一 2xx、无票据副作用增加、本次标记被无票据执行、或 ticketCheck=off）；
#         3 无法判定（healthz / tools/list 不通、非预期状态码）。末行恒为 JSON 摘要。

TOOL_URL="${TOOL_URL:?需要 TOOL_URL}"
TOOL_URL="${TOOL_URL%/}"
NL='
'
REASONS=""
INCONCLUSIVE=0
BYPASS=0

# 原因写进 JSON 字符串：去掉引号、反斜杠与控制字符，保证末行恒为合法 JSON。
clean() { printf '%s' "$1" | tr -d '\042\134\000-\037'; }
note() { REASONS="${REASONS}${REASONS:+,}\"$(clean "$1")\""; }

# http <方法> <路径> [请求体]：设置 CODE 与 BODY（curl 失败时 CODE=000）。
http() {
  if [ -n "${3:-}" ]; then
    out=$(curl -sS -m 10 -X "$1" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
      --data "$3" -w "${NL}%{http_code}" "$TOOL_URL$2" 2>/dev/null)
  else
    out=$(curl -sS -m 10 -X "$1" -w "${NL}%{http_code}" "$TOOL_URL$2" 2>/dev/null)
  fi
  CODE=$(printf '%s\n' "$out" | tail -n1)
  BODY=$(printf '%s\n' "$out" | sed '$d')
  case "$CODE" in [0-9][0-9][0-9]) ;; *) CODE=000 ;; esac
}

field_num() { printf '%s' "$BODY" | sed -n "s/.*\"$1\":\([0-9][0-9]*\).*/\1/p" | head -n1; }
field_str() { printf '%s' "$BODY" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -n1; }
hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
uuid() { h=$(hex 16); echo "$(echo "$h" | cut -c1-8)-$(echo "$h" | cut -c9-12)-4$(echo "$h" | cut -c14-16)-a$(echo "$h" | cut -c18-20)-$(echo "$h" | cut -c21-32)"; }

summary() {
  echo "{\"verdict\":\"$1\",\"ticketCheck\":\"${TICKET_CHECK:-unknown}\",\"unticketedDelta\":${DELTA:-null},\"marker\":\"${M:-}\",\"markerExecuted\":${MARKER_EXECUTED:-false},\"steps\":{\"healthz\":${S_HEALTH:-0},\"list\":${S_LIST:-0},\"missing\":${S_MISSING:-0},\"forged\":${S_FORGED:-0},\"malformed\":${S_MALFORMED:-0},\"batch\":${S_BATCH:-0}},\"reasons\":[${REASONS}]}"
}

# ① healthz
http GET /healthz
S_HEALTH=$CODE
TICKET_CHECK=$(clean "$(field_str ticketCheck)")
echo "healthz $CODE ticketCheck=${TICKET_CHECK:-?}"
if [ "$CODE" != 200 ]; then INCONCLUSIVE=1; note "healthz 非 200（${CODE}）"; fi
if [ "$TICKET_CHECK" = off ]; then BYPASS=1; note "工具报告 ticketCheck=off"; fi

# ② tools/list（不需要票据）：放行位置连不上工具即无法判定，唯一的提前退出。
http POST /mcp '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
S_LIST=$CODE
echo "tools/list $CODE"
if [ "$CODE" != 200 ]; then
  note "tools/list 非 200（${CODE}）：放行位置连不上工具"
  summary inconclusive
  exit 3
fi

# ③ 基线副作用计数与本次标记
http GET /effects
BEFORE=$(field_num unticketed)
M="auth-probe-$(hex 8)"
echo "effects before unticketed=${BEFORE:-?} marker=$M"
if [ -z "$BEFORE" ]; then INCONCLUSIVE=1; note "无法读取 /effects"; fi

call() { echo "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"demo_echo\",\"arguments\":{\"message\":\"$M\"}$2}}"; }

# expect_reject <步骤名> <期望状态> <期望 reason 正则（空则不查）>
expect_reject() {
  echo "$1 $CODE $(field_str reason)"
  case "$CODE" in
    2[0-9][0-9]) BYPASS=1; note "$1 返回 ${CODE}：请求被执行" ;;
    "$2")
      if [ -n "$3" ] && ! field_str reason | grep -Eq "^($3)\$"; then
        INCONCLUSIVE=1; note "$1 拒绝原因非预期：$(field_str reason)"
      fi ;;
    *) INCONCLUSIVE=1; note "$1 状态非预期：$CODE" ;;
  esac
}

# ④ 无票据
http POST /mcp "$(call 2 '')"
S_MISSING=$CODE; expect_reject missing 401 missing_ticket
# ⑤ 伪造票据（合法形状、随机 id）
# 先拼进变量：嵌套在 "$(…)" 里的转义引号在 bash 的 posix 模式下会被拆开并触发花括号展开。
D=$(uuid); A=$(uuid)
FORGED=',"_meta":{"io.aster/guard-consume":{"decisionId":"'"$D"'","attemptId":"'"$A"'","envelope":{"principal":{"id":"auth-probe","type":"agent"},"action":{"name":"demo_echo"}}}}'
http POST /mcp "$(call 3 "$FORGED")"
S_FORGED=$CODE; expect_reject forged 401 'guard_unavailable|not_allowed'
# ⑥ 畸形票据
http POST /mcp "$(call 4 ',"_meta":{"io.aster/guard-consume":{"decisionId":"x"}}')"
S_MALFORMED=$CODE; expect_reject malformed 401 malformed_ticket
# ⑦ 批量请求
http POST /mcp "[$(call 5 '')]"
S_BATCH=$CODE; expect_reject batch 400 ''

# ⑧ 副作用：总的无票据计数增量，与本次标记是否被无票据执行
http GET /effects
AFTER=$(field_num unticketed)
if [ -n "$BEFORE" ] && [ -n "$AFTER" ]; then DELTA=$((AFTER - BEFORE)); else DELTA=null; INCONCLUSIVE=1; note "无法读取 /effects"; fi
http GET "/effects?marker=$M"
MARKER_EXECUTED=false
if [ "$CODE" = 200 ]; then
  if printf '%s' "$BODY" | grep -q '"decisionId":null'; then MARKER_EXECUTED=true; fi
else
  INCONCLUSIVE=1; note "无法按标记读取 /effects（${CODE}）"
fi
echo "effects after unticketed=${AFTER:-?} delta=$DELTA markerExecuted=$MARKER_EXECUTED"
if [ "$DELTA" != null ] && [ "$DELTA" -gt 0 ]; then BYPASS=1; note "无票据副作用增加 $DELTA"; fi
# 计数回退说明工具在两次读取之间重启（进程内日志清零），本次的副作用证据不可信。
if [ "$DELTA" != null ] && [ "$DELTA" -lt 0 ]; then INCONCLUSIVE=1; note "副作用计数回退（${DELTA}）：工具在探测期间重启"; fi
if [ "$MARKER_EXECUTED" = true ]; then BYPASS=1; note "本次标记被无票据执行"; fi

if [ "$BYPASS" = 1 ]; then summary bypass; exit 1; fi
if [ "$INCONCLUSIVE" = 1 ]; then summary inconclusive; exit 3; fi
summary pass
exit 0
