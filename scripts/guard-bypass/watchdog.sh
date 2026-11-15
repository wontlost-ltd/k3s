#!/usr/bin/env bash
# 探针工作流看门狗（计划 Task 8 watchdog job）：没有证据就判红。
# 用法：watchdog.sh <now-epoch> <api-json-file|->
#   api JSON：{"workflow_runs": [...], "latest_jobs": {"jobs": [...]}}——前者为
#   GET /repos/wontlost-ltd/k3s/actions/workflows/guard-bypass-probe.yml/runs?branch=main&status=completed（已排除本次运行），
#   后者为其中最近一次运行的 GET …/runs/<id>/jobs。
# 通过条件：最近一次已完成运行的 probe job 结论为 success，且完成时间距今 ≤ 36 小时。
# 无任何已完成运行、查询失败（文件为空 / 非 JSON）、job 缺失或被跳过都判失败。
set -euo pipefail
now="${1:?用法：watchdog.sh <now-epoch> <api-json-file|->}"
src="${2:?用法：watchdog.sh <now-epoch> <api-json-file|->}"
json="$(cat "$src")"
fail() { echo "::error::guard-bypass 看门狗：$*"; exit 1; }
jq -e 'type == "object" and (.workflow_runs | type) == "array"' >/dev/null 2>&1 <<<"$json" || fail "GitHub API 查询失败或返回为空——查不到不能当作有证据"
latest="$(jq -c '.workflow_runs | sort_by(.updated_at) | last // empty' <<<"$json")"
[[ -n "$latest" ]] || fail "main 上没有任何已完成的 guard-bypass-probe 运行"
run_url="$(jq -r '.html_url // .id' <<<"$latest")"
probe="$(jq -c '[(.latest_jobs.jobs // [])[] | select(.name == "probe")] | last // empty' <<<"$json")"
[[ -n "$probe" ]] || fail "最近一次运行（${run_url}）没有 probe job 的记录"
conclusion="$(jq -r '.conclusion // "none"' <<<"$probe")"
[[ "$conclusion" == success ]] || fail "最近一次运行（${run_url}）的 probe job 结论为 ${conclusion}"
completed="$(jq -r '.completed_at // empty | fromdateiso8601' <<<"$probe" 2>/dev/null || true)"
[[ "$completed" =~ ^[0-9]+$ ]] || fail "probe job 缺 completed_at"
age=$((now - completed))
(( age <= 36 * 3600 )) || fail "最近一次成功的探针已是 $((age / 3600)) 小时前（> 36 h）：Environment / secret / 工作流可能失效"
echo "看门狗通过：最近一次 probe job 成功于 $((age / 3600)) 小时前（${run_url}）"
