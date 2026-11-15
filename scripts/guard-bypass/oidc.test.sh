#!/usr/bin/env bash
# oidc-kubeconfig.sh 与 assert-identity.sh 的离线测试（aster-api ADR 0057 §4.2；计划 Task 4）。
# 假 curl 充当 runner 的 ID token 端点（返回自造 JWT，签名不验——验签是 apiserver 的事），假 kubectl 返回预设身份。
# 用法：bash scripts/guard-bypass/oidc.test.sh；依赖 jq。
# shellcheck disable=SC2015  # pass 恒成功，A && pass || fail 即 if-else
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/guard-bypass/lib.sh
source "$HERE/lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1${2:+：$2}"; FAILED=1; }

NOW="$(date +%s)"
b64url() { base64 | tr -d '=\n' | tr '/+' '_-'; }
# jwt <jq 改动>：以合规 claim 为基础改一处
jwt() {
  local p
  p="$(jq -nc --argjson now "$NOW" --arg aud "$PROBE_OIDC_AUDIENCE" --arg iss "$PROBE_OIDC_ISSUER" --arg repo "$PROBE_OIDC_REPOSITORY" \
    --arg env "$PROBE_OIDC_ENVIRONMENT" --arg wf "$PROBE_OIDC_WORKFLOW_REF" '{iss: $iss, aud: $aud, repository: $repo, environment: $env,
      job_workflow_ref: $wf, ref: "refs/heads/main", run_id: "42", iat: $now, nbf: $now, exp: ($now + 300)}' | jq -c "${1:-.}")"
  printf '%s.%s.c2ln' "$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)" "$(printf '%s' "$p" | b64url)"
}

BIN="$WORK/bin"; mkdir -p "$BIN"
cat >"$BIN/curl" <<'SH'
#!/usr/bin/env bash
# 假 ID token 端点：记录调用；返回 $FAKE_JWT_FILE 的内容作为 value。
echo "$*" >>"$FAKE_CURL_LOG"
[[ "${FAKE_CURL_FAIL:-0}" == 1 ]] && exit 22
printf '{"count":1,"value":"%s"}' "$(cat "$FAKE_JWT_FILE")"
SH
cat >"$BIN/kubectl" <<'SH'
#!/usr/bin/env bash
# 假 kubectl（真实路径）：记录 KUBECONFIG 与参数。
echo "KUBECONFIG=${KUBECONFIG:-} $*" >>"$FAKE_KUBECTL_LOG"
case "$*" in
  "auth whoami"*) printf '%s' "$FAKE_WHO" ;;
  *) echo ok ;;
esac
SH
chmod +x "$BIN"/*
printf -- '-----BEGIN CERTIFICATE-----\nTUlJ\n-----END CERTIFICATE-----\n' >"$WORK/ca.crt"

D="$WORK/oidc"
# init [额外环境…]：stdout → $WORK/out，stderr → $WORK/err，返回退出码
init() {
  local code=0
  rm -rf "$D"; : >"$WORK/curl.log"
  env PATH="$BIN:$PATH" CURL="$BIN/curl" FAKE_CURL_LOG="$WORK/curl.log" FAKE_JWT_FILE="$WORK/jwt" \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://runner.example/idtoken?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token "$@" \
    bash "$HERE/oidc-kubeconfig.sh" init --dir "$D" --server https://158.179.18.241:6443 --ca "$WORK/ca.crt" >"$WORK/out" 2>"$WORK/err" || code=$?
  echo "$code"
}

echo "== oidc-kubeconfig init"
jwt >"$WORK/jwt"; c="$(init)"
kc="$D/kubeconfig"
if [[ "$c" == 0 && "$(cat "$WORK/out")" == "$kc" && -s "$D/token" ]] && [[ "$(cat "$D/token")" == "$(cat "$WORK/jwt")" ]] &&
   [[ "$(yq '.users[0].user | keys | join(",")' "$kc")" == tokenFile && "$(yq '.users[0].user.tokenFile' "$kc")" == "$D/token" ]] &&
   [[ "$(yq '.clusters[0].cluster.server' "$kc")" == https://158.179.18.241:6443 ]] &&
   [[ "$(yq '.clusters[0].cluster.certificate-authority-data' "$kc" | base64 -d)" == "$(cat "$WORK/ca.crt")" ]] &&
   ! grep -q 'exec' "$kc" && [[ -x "$D/bin/kubectl" ]] &&
   grep -q 'audience=k3s-guard-probe' "$WORK/curl.log" && grep -q 'Authorization: bearer req-token' "$WORK/curl.log"; then
  pass "init_writes_exec_free_kubeconfig_with_token_file（server + CA + tokenFile，无 exec；audience 与请求头正确）"
else fail init_writes_exec_free_kubeconfig_with_token_file "$c $(cat "$WORK/err")"; fi
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
[[ "$(mode_of "$D/token")" == 600 && "$(mode_of "$kc")" == 600 ]] && pass "token 与 kubeconfig 为 0600" || fail "文件权限" "$(mode_of "$D/token") $(mode_of "$kc")"
! grep -qF "$(cut -d. -f2 "$WORK/jwt")" "$WORK/out" "$WORK/err" && pass init_never_prints_token || fail init_never_prints_token

jwt >"$WORK/jwt"
c="$(init ACTIONS_ID_TOKEN_REQUEST_URL=)"; [[ "$c" == 3 && ! -e "$D/kubeconfig" ]] && grep -q 'id-token: write' "$WORK/err" &&
  pass "init_without_id_token_env_is_3（提示 id-token: write）" || fail init_without_id_token_env_is_3 "$c"
c="$(init FAKE_CURL_FAIL=1)"; [[ "$c" == 3 && ! -e "$D/kubeconfig" ]] && pass "取 token 失败判 3" || fail "取 token 失败" "$c"
for case in 'aud=.aud = "sts.amazonaws.com"' 'aud_array_ok=.aud = ["x", "k3s-guard-probe"]' 'iss=.iss = "https://evil.example"' \
            'repo=.repository = "wontlost-ltd/other"' 'wf=.job_workflow_ref = "wontlost-ltd/k3s/.github/workflows/x.yml@refs/heads/main"' \
            'env=.environment = "prod"' 'noenv=del(.environment)' 'ref=.ref = "refs/heads/dev"' "expired=.exp = $((NOW - 10))"; do
  name="${case%%=*}" patch="${case#*=}"
  jwt "$patch" >"$WORK/jwt"; c="$(init)"
  if [[ "$name" == aud_array_ok ]]; then
    [[ "$c" == 0 ]] && pass "aud 为数组且含 k3s-guard-probe 时接受" || fail "aud 数组" "$c $(cat "$WORK/err")"
  else
    [[ "$c" == 3 && ! -e "$D/kubeconfig" ]] && pass "init_rejects_${name}（判 3，不写 kubeconfig）" || fail "init_rejects_${name}" "$c"
  fi
done
printf 'not-a-jwt' >"$WORK/jwt"; c="$(init)"; [[ "$c" == 3 ]] && pass "不可解析的 token 判 3" || fail "不可解析 token" "$c"
c=0; bash "$HERE/oidc-kubeconfig.sh" init --dir "$D" >/dev/null 2>&1 || c=$?; [[ "$c" == 2 ]] && pass "缺参数退出 2" || fail "缺参数" "$c"

echo "== 包装脚本（按需刷新）"
jwt >"$WORK/jwt"; init >/dev/null
run_wrapper() {
  env PATH="$BIN:$PATH" CURL="$BIN/curl" FAKE_CURL_LOG="$WORK/curl.log" FAKE_JWT_FILE="$WORK/jwt" FAKE_KUBECTL_LOG="$WORK/k.log" FAKE_WHO=x \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://runner.example/idtoken?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token KUBECONFIG=/static/kubeconfig "$@" \
    "$D/bin/kubectl" get pods -n aster-agents >/dev/null 2>&1
}
: >"$WORK/curl.log"; : >"$WORK/k.log"; run_wrapper
[[ ! -s "$WORK/curl.log" ]] && grep -q "^KUBECONFIG=$D/kubeconfig get pods -n aster-agents" "$WORK/k.log" &&
  pass "wrapper_keeps_fresh_token（不重取；KUBECONFIG 强制指向 OIDC kubeconfig）" || fail wrapper_keeps_fresh_token "$(cat "$WORK/k.log")"
echo $((NOW - 600)) >"$D/token.fetched-at"; jwt '.run_id = "43"' >"$WORK/jwt"; : >"$WORK/curl.log"; run_wrapper
[[ -s "$WORK/curl.log" && "$(cat "$D/token")" == "$(cat "$WORK/jwt")" ]] && pass "wrapper_refreshes_stale_token（超过 60 s 重取）" || fail wrapper_refreshes_stale_token
jwt ".exp = $((NOW + 60))" >"$WORK/jwt"; cp "$WORK/jwt" "$D/token"; date +%s >"$D/token.fetched-at"; jwt >"$WORK/jwt"; : >"$WORK/curl.log"; run_wrapper
[[ -s "$WORK/curl.log" ]] && pass "剩余有效期 < 120 s 时重取（不论获取多久）" || fail "临期重取"
echo $((NOW - 600)) >"$D/token.fetched-at"; : >"$WORK/k.log"; c=0; run_wrapper FAKE_CURL_FAIL=1 || c=$?
[[ "$c" != 0 && ! -s "$WORK/k.log" ]] && pass "刷新失败时不带旧 token 调 kubectl（非 0 退出）" || fail "刷新失败" "$c"

echo "== assert-identity"
mkdir -p "$WORK/oidc2/bin"
cat >"$WORK/oidc2/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "auth whoami"*) printf '%s' "$FAKE_OIDC_WHO" ;;
  "auth can-i create pods -n aster-agents") echo "${FAKE_CAN_CREATE:-yes}"; [[ "${FAKE_CAN_CREATE:-yes}" == yes ]] ;;
  "auth can-i get secrets -n aster-agents") echo "${FAKE_CAN_SECRETS:-no}"; [[ "${FAKE_CAN_SECRETS:-no}" == yes ]] ;;
  *) exit 99 ;;
esac
SH
chmod +x "$WORK/oidc2/bin/kubectl"
assert() { # assert <mode> [env…] → 退出码
  local mode="$1" code=0; shift
  env KUBECTL="$BIN/kubectl" FAKE_KUBECTL_LOG="$WORK/k.log" FAKE_WHO="$PROBE_SA_USER" FAKE_OIDC_WHO="$PROBE_OIDC_USER" "$@" \
    bash "$HERE/assert-identity.sh" "$mode" --oidc-dir "$WORK/oidc2" >"$WORK/out" 2>&1 || code=$?
  echo "$code"
}
[[ "$(assert static)" == 0 && "$(assert static FAKE_WHO=system:admin)" == 3 && "$(assert static FAKE_WHO="$PROBE_OIDC_USER")" == 3 ]] &&
  pass "assert_static_requires_sa" || fail assert_static_requires_sa
[[ "$(assert oidc)" == 0 && "$(assert oidc FAKE_OIDC_WHO=system:admin)" == 3 && "$(assert oidc FAKE_OIDC_WHO="$PROBE_SA_USER")" == 3 ]] &&
  pass "assert_oidc_requires_oidc_user" || fail assert_oidc_requires_oidc_user
r="$(assert dual) $(assert dual FAKE_WHO=kubernetes-admin) $(assert dual FAKE_OIDC_WHO=x) $(assert dual FAKE_CAN_CREATE=no) $(assert dual FAKE_CAN_SECRETS=yes) $(assert oidc FAKE_CAN_SECRETS=yes)"
[[ "$r" == "0 3 3 3 3 3" ]] && pass "assert_dual_checks_both_and_rbac（两个身份 + OIDC 能建 Pod、不能读 Secret）" || fail assert_dual_checks_both_and_rbac "$r"
[[ "$(assert admin)" == 2 && "$(assert '')" == 2 ]] && pass assert_unknown_mode_is_2 || fail assert_unknown_mode_is_2
c="$(env KUBECTL="$BIN/kubectl" FAKE_KUBECTL_LOG="$WORK/k.log" FAKE_OIDC_WHO="$PROBE_OIDC_USER" bash "$HERE/assert-identity.sh" oidc --oidc-dir "$WORK/none" >/dev/null 2>&1; echo $?)"
[[ "$c" == 3 ]] && pass "oidc 模式缺包装脚本判 3" || fail "缺包装脚本" "$c"

echo "== 集群 CA"
CA="$HERE/k3s-server-ca.crt"
if [[ -s "$CA" ]] && fp="$(openssl x509 -in "$CA" -noout -fingerprint -sha256 2>/dev/null)" &&
   [[ "${fp#*=}" == 43:BB:3B:FA:F0:83:87:E0:46:D5:91:82:79:D4:54:32:2C:1F:D4:32:2C:35:8A:DF:8A:43:63:B2:5A:AC:A4:8B ]] &&
   [[ "$(grep -c 'BEGIN CERTIFICATE' "$CA")" == 1 ]] && ! grep -q 'PRIVATE KEY' "$CA"; then
  pass "k3s-server-ca.crt 恰为一张证书、指纹与 ADR 0057 §1 一致、不含私钥"
else fail "k3s-server-ca.crt"; fi

if [[ "$FAILED" != 0 ]]; then echo "oidc.test.sh：有用例失败" >&2; exit 1; fi
echo "oidc.test.sh：全部通过"
