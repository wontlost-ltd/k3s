#!/usr/bin/env bash
# apps/aster-lang/guard/probe/auth-probe.sh 的表驱动测试（aster-api ADR 0054 §12 D7）。离线：PATH 注入假 curl
# （testdata/auth-bin/curl，POSIX sh），回放 testdata/curl/base 与各用例覆盖的响应。以 `sh` 运行被测脚本
# （CI 上为 dash；生产为 busybox sh）。用法：bash scripts/guard-bypass/auth-probe.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$HERE/../../apps/aster-lang/guard/probe/auth-probe.sh"
export FAKE_BASE="$HERE/testdata/curl/base"
export PATH="$HERE/testdata/auth-bin:$PATH"
export TOOL_URL=http://demo-tool.aster-tools.svc.cluster.local:8080
export WARMUP_SECONDS=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

new_case() {
  NAME="$1"
  export FAKE_CASE="$WORK/$NAME/case" FAKE_OUT="$WORK/$NAME/out"
  mkdir -p "$FAKE_CASE" "$FAKE_OUT"
  : >"$FAKE_OUT/curl.log"
  CASE="$FAKE_CASE"
}
set_resp() { printf '%s' "$2" >"$CASE/$1.code"; printf '%s' "$3" >"$CASE/$1.body"; }
fail() { echo "  ✗ ${NAME}：$*"; FAILED=1; }
ok() { echo "  ✓ ${NAME}"; }
run() {
  local want="$1" code=0
  OUT="$(sh "$PROBE" 2>"$FAKE_OUT/stderr")" || code=$?
  SUMMARY="$(tail -n1 <<<"$OUT")"
  jq -e . <<<"$SUMMARY" >/dev/null 2>&1 || { fail "末行不是 JSON：${SUMMARY}"; return 1; }
  [[ "$code" == "$want" ]] || { fail "退出码 ${code} ≠ 期望 ${want}；${OUT}"; return 1; }
}
summary_has() { jq -e "$1" <<<"$SUMMARY" >/dev/null || { fail "摘要不满足 $1：${SUMMARY}"; return 1; }; }
steps_sent() { grep -c "$1" "$FAKE_OUT/curl.log" || true; }

new_case all_rejected_is_pass
run 0 && summary_has '.verdict == "pass" and .ticketCheck == "on" and .unticketedDelta == 0 and .markerExecuted == false
  and .steps == {"healthz":200,"list":200,"missing":401,"forged":401,"malformed":401,"batch":400}
  and (.marker | test("^auth-probe-[0-9a-f]{16}$"))' && ok

new_case forged_not_allowed_is_pass
set_resp forged 401 '{"error":"ticket_rejected","reason":"not_allowed"}'
run 0 && ok

new_case unticketed_call_executes_is_bypass
set_resp missing 200 '{"result":{"content":[]},"jsonrpc":"2.0","id":2}'
set_resp effects2 200 '{"count":4,"unticketed":1,"last":[]}'
run 1 && summary_has '.verdict == "bypass" and .unticketedDelta == 1 and .steps.missing == 200' && ok

new_case marker_executed_is_bypass
set_resp effects-marker 200 '{"count":4,"unticketed":1,"last":[{"tool":"demo_echo","marker":"m","decisionId":null,"attemptId":null}]}'
run 1 && summary_has '.markerExecuted == true' && ok

new_case healthz_reports_off_is_bypass
set_resp healthz 200 '{"status":"ok","ticketCheck":"off"}'
run 1 && summary_has '.verdict == "bypass" and .ticketCheck == "off"' && ok

new_case ticket_check_off_still_exercises_calls
set_resp healthz 200 '{"status":"ok","ticketCheck":"off"}'
for s in missing forged malformed; do set_resp "$s" 200 '{"result":{"content":[]},"jsonrpc":"2.0","id":9}'; done
set_resp effects2 200 '{"count":6,"unticketed":3,"last":[]}'
set_resp effects-marker 200 '{"count":6,"unticketed":3,"last":[{"marker":"m","decisionId":null}]}'
if run 1; then
  sent_ok=1
  for s in missing forged malformed batch effects-marker; do
    [[ "$(steps_sent " $s\$")" == 1 ]] || { fail "关闭票据核对时也必须发出 ${s}"; sent_ok=0; }
  done
  [[ "$sent_ok" == 1 ]] && summary_has '.unticketedDelta == 3 and .steps.missing == 200 and .markerExecuted == true' && ok
fi

new_case tools_list_unreachable_is_inconclusive
echo 7 >"$CASE/list.exit"
run 3 && summary_has '.verdict == "inconclusive" and .steps.list == 0' &&
  { [[ "$(steps_sent ' missing$')" == 0 ]] || fail "tools/list 不通时不应继续"; } && ok

new_case unexpected_500_is_inconclusive
set_resp malformed 500 '{"error":"internal_error"}'
run 3 && summary_has '.steps.malformed == 500' && ok

new_case unexpected_reason_is_inconclusive
set_resp forged 401 '{"error":"ticket_rejected","reason":"action_mismatch"}'
run 3 && ok

new_case hostile_reason_keeps_summary_json
printf '401' >"$CASE/forged.code"
printf '%s' '{"error":"ticket_rejected","reason":"a\\b"}' >"$CASE/forged.body"
printf '200' >"$CASE/healthz.code"
printf '%s' '{"status":"ok","ticketCheck":"o\\n"}' >"$CASE/healthz.body"
run 3 && ok

new_case effects_counter_reset_is_inconclusive
set_resp effects1 200 '{"count":9,"unticketed":2,"last":[]}'
set_resp effects2 200 '{"count":0,"unticketed":0,"last":[]}'
run 3 && summary_has '.unticketedDelta == -2' && ok

new_case batch_accepted_is_bypass
set_resp batch 200 '[{"result":{},"jsonrpc":"2.0","id":5}]'
run 1 && summary_has '.steps.batch == 200' && ok

new_case healthz_down_is_inconclusive
echo 28 >"$CASE/healthz.exit"
run 3 && summary_has '.steps.healthz == 0 and .steps.missing == 401' && ok

new_case healthz_warmup_retries_until_reachable
# 头两次 healthz 被 REJECT（kube-router 同步延迟），第三次 200：照常完成全部步骤并判通过。
printf '%s\n' 7 7 >"$CASE/healthz.exits"
if WARMUP_SECONDS=10 run 0; then
  if [[ "$(steps_sent ' healthz$')" == 3 ]]; then ok; else fail "healthz 应重试至可达（发出 $(steps_sent ' healthz$') 次）"; fi
fi

new_case effects_unreadable_is_inconclusive
set_resp effects2 500 'oops'
run 3 && summary_has '.unticketedDelta == null' && ok

if [[ "$FAILED" != 0 ]]; then
  echo "auth-probe.test.sh：有用例失败" >&2
  exit 1
fi
echo "auth-probe.test.sh：全部通过"
