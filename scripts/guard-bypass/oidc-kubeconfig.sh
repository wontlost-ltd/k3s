#!/usr/bin/env bash
# 探针的 GitHub OIDC 凭证（aster-api ADR 0057 §4.2）：在 probe job 内向 runner 取 audience=k3s-guard-probe 的 ID token，
# 生成**不含 exec 插件**的 kubeconfig（server + 集群 CA + tokenFile）与一个按需刷新 token 的 kubectl 包装脚本。
#
#   oidc-kubeconfig.sh init --dir <d> --server <https://host:port> --ca <ca.crt> [--kubectl <真实 kubectl>]
#     → <d>/token、<d>/token.fetched-at、<d>/kubeconfig（均 0600）、<d>/bin/kubectl；stdout 只输出 kubeconfig 路径
#   oidc-kubeconfig.sh refresh --dir <d>
#     → token 获取已超过 OIDC_MAX_AGE 秒（缺省 60）或剩余有效期 < OIDC_MIN_REMAINING 秒（缺省 120）时重取
#
# 为什么要刷新：GitHub 对 ID token 有效期没有文档承诺（公开样本从 5 分钟到数小时），而 probe job 最长 45 分钟；
# 每次 kubectl 调用前保证 token 新鲜，就不依赖有效期长短。token 原子替换（同目录临时文件 + mv），并发调用安全。
# 本地 claim 核对只为给出可读的错误；权威校验在 apiserver（hosts/k3s-server/.../authentication-config.yaml）。
# 退出码：0；2 参数错误；3 无法取得合规 token（job 未授予 id-token: write、端点失败、claim 不符、已过期）。token 从不回显。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/guard-bypass/lib.sh
source "$HERE/lib.sh"

CURL="${CURL:-curl}"
MAX_AGE="${OIDC_MAX_AGE:-60}"
MIN_REMAINING="${OIDC_MIN_REMAINING:-120}"
die3() { echo "::error::$*" >&2; exit 3; }

# fetch <dir>：取 token → 核对 claim → 原子写入 <dir>/token 与获取时刻
fetch() {
  local dir="$1" resp token claims now problems tmp
  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] ||
    die3 "没有 ACTIONS_ID_TOKEN_REQUEST_URL / _TOKEN：probe job 未授予 permissions.id-token: write"
  resp="$("$CURL" -fsS --max-time 20 --retry 2 -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${PROBE_OIDC_AUDIENCE}")" || die3 "向 runner 取 OIDC token 失败"
  token="$(jq -r '.value // empty' <<<"$resp" 2>/dev/null || true)"
  [[ "$token" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$ ]] || die3 "runner 返回的不是 JWT"
  claims="$(jwt_claims <<<"$token")" || true
  now="$(date +%s)"
  problems="$(jq -r --arg aud "$PROBE_OIDC_AUDIENCE" --arg iss "$PROBE_OIDC_ISSUER" --arg repo "$PROBE_OIDC_REPOSITORY" \
    --arg env "$PROBE_OIDC_ENVIRONMENT" --arg wf "$PROBE_OIDC_WORKFLOW_REF" --argjson now "$now" '
    [ (if .iss != $iss then "iss=\(.iss)" else empty end),
      (if ([.aud] | flatten | index($aud)) == null then "aud=\(.aud)" else empty end),
      (if .repository != $repo then "repository=\(.repository)" else empty end),
      (if .environment != $env then "environment=\(.environment)" else empty end),
      (if .job_workflow_ref != $wf then "job_workflow_ref=\(.job_workflow_ref)" else empty end),
      (if .ref != "refs/heads/main" then "ref=\(.ref)" else empty end),
      (if ((.exp // 0) | tonumber? // 0) <= $now then "已过期" else empty end) ] | join("；")' <<<"$claims" 2>/dev/null)" ||
    die3 "OIDC token 的 payload 无法解析"
  [[ -z "$problems" ]] || die3 "OIDC token 的 claim 与探针信任条件不符（apiserver 也会拒绝）：$problems"
  umask 077
  tmp="$(mktemp "$dir/.token.XXXXXX")"
  printf '%s' "$token" >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$dir/token"
  echo "$now" >"$dir/token.fetched-at"
}

do_refresh() {
  local dir="$1" fetched exp now
  now="$(date +%s)"
  fetched="$(cat "$dir/token.fetched-at" 2>/dev/null || echo 0)"
  exp="$(jwt_claims <"$dir/token" 2>/dev/null | jq -r '.exp // 0' 2>/dev/null || echo 0)"
  [[ "$fetched" =~ ^[0-9]+$ ]] || fetched=0
  [[ "$exp" =~ ^[0-9]+$ ]] || exp=0
  if (( now - fetched > MAX_AGE || exp - now < MIN_REMAINING )); then fetch "$dir"; fi
}

cmd="${1:-}"; [[ $# -gt 0 ]] && shift
dir="" server="" ca="" real_kubectl=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="${2:-}"; shift 2 ;;
    --server) server="${2:-}"; shift 2 ;;
    --ca) ca="${2:-}"; shift 2 ;;
    --kubectl) real_kubectl="${2:-}"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
[[ -n "$dir" ]] || { echo "用法：oidc-kubeconfig.sh init|refresh --dir <d> …" >&2; exit 2; }

case "$cmd" in
  refresh) do_refresh "$dir" ;;
  init)
    [[ "$server" =~ ^https://[^/[:space:]]+$ ]] || { echo "--server 须为 https://<host>:<port>" >&2; exit 2; }
    [[ -s "$ca" ]] || { echo "--ca 文件不存在或为空" >&2; exit 2; }
    if [[ -z "$real_kubectl" ]]; then
      # 跳过本目录下的包装脚本，找真正的 kubectl
      real_kubectl="$(type -ap kubectl | grep -vxF "$dir/bin/kubectl" | head -n1 || true)"
    fi
    [[ -x "$real_kubectl" ]] || { echo "找不到 kubectl" >&2; exit 2; }
    umask 077
    mkdir -p "$dir/bin"
    chmod 0700 "$dir"
    fetch "$dir"
    jq -n --arg server "$server" --arg ca "$(base64 <"$ca" | tr -d '\n')" --arg tf "$dir/token" '{
      apiVersion: "v1", kind: "Config", "current-context": "probe",
      clusters: [{name: "k3s", cluster: {server: $server, "certificate-authority-data": $ca}}],
      users: [{name: "guard-probe-oidc", user: {tokenFile: $tf}}],
      contexts: [{name: "probe", context: {cluster: "k3s", user: "guard-probe-oidc"}}]}' >"$dir/kubeconfig"
    chmod 0600 "$dir/kubeconfig"
    # 包装脚本：先刷新 token（失败则不调用 kubectl），再强制使用 OIDC kubeconfig
    {
      echo '#!/usr/bin/env bash'
      echo '# 由 oidc-kubeconfig.sh init 生成：每次调用前按需刷新 OIDC token，并固定使用 OIDC kubeconfig。'
      echo 'set -euo pipefail'
      printf 'bash %q refresh --dir %q >&2 || exit 3\n' "$HERE/oidc-kubeconfig.sh" "$dir"
      printf 'export KUBECONFIG=%q\n' "$dir/kubeconfig"
      printf 'exec %q "$@"\n' "$real_kubectl"
    } >"$dir/bin/kubectl"
    chmod 0700 "$dir/bin/kubectl"
    echo "$dir/kubeconfig"
    ;;
  *) echo "用法：oidc-kubeconfig.sh init|refresh --dir <d> …" >&2; exit 2 ;;
esac
