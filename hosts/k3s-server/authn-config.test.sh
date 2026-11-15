#!/usr/bin/env bash
# 结构化认证配置、apiserver drop-in 与探针身份跨文件一致性的离线测试（aster-api ADR 0057 §4.1 / D6–D8；计划 Task 2）。
#
# CEL 的求值离线做不了（apiserver 才是权威）；这里逐字断言规则集合与映射，并断言身份常量在
# lib.sh、认证配置、审计策略、RBAC、准入策略、工作流之间完全一致——任何一处漂移，OIDC 身份就会
# 「认证成功但没权限」或者更糟的「有权限但不受准入策略约束」。
# 用法：bash hosts/k3s-server/authn-config.test.sh；依赖 yq（mikefarah v4）、jq、kustomize。
# shellcheck disable=SC2015  # pass 恒成功，A && pass || fail 即 if-else
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
F="$HERE/files/etc/rancher/k3s"
AUTHN="$F/aster/authentication-config.yaml"
AUDIT="$F/aster/audit-policy.yaml"
DROP_AUDIT="$F/config.yaml.d/50-aster-audit.yaml"
DROP_OIDC="$F/config.yaml.d/60-aster-oidc.yaml"
WF="$ROOT/.github/workflows/guard-bypass-probe.yml"
# shellcheck source=scripts/guard-bypass/lib.sh
source "$ROOT/scripts/guard-bypass/lib.sh"
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1${2:+：$2}"; FAILED=1; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
j() { yq -o=json -I=0 "$1" "$2" 2>/dev/null || echo "yq 解析失败：$2"; }

echo "== lib.sh 常量"
check "身份常量齐全且取值符合 ADR 0057 §4.1" bash -c '
  [[ "'"${PROBE_SA_USER:-}"'" == system:serviceaccount:aster-guard:guard-bypass-probe &&
     "'"${PROBE_OIDC_USER:-}"'" == github-actions:wontlost-ltd/k3s:guard-probe &&
     "'"${PROBE_OIDC_AUDIENCE:-}"'" == k3s-guard-probe &&
     "'"${PROBE_OIDC_ISSUER:-}"'" == https://token.actions.githubusercontent.com &&
     "'"${PROBE_OIDC_REPOSITORY:-}"'" == wontlost-ltd/k3s &&
     "'"${PROBE_OIDC_REPOSITORY_ID:-}"'" == 1116032527 &&
     "'"${PROBE_OIDC_OWNER_ID:-}"'" == 81835091 &&
     "'"${PROBE_OIDC_WORKFLOW_REF:-}"'" == wontlost-ltd/k3s/.github/workflows/guard-bypass-probe.yml@refs/heads/main &&
     "'"${PROBE_OIDC_ENVIRONMENT:-}"'" == guard-probe &&
     "'"${PROBE_OIDC_SUB:-}"'" == repo:wontlost-ltd/k3s:environment:guard-probe ]]'

echo "== AuthenticationConfiguration"
if [[ ! -s "$AUTHN" ]]; then fail "认证配置存在" "$AUTHN"; else
  check "apiVersion apiserver.config.k8s.io/v1、kind AuthenticationConfiguration、只有 jwt 键" bash -c "
    [[ \"\$(yq '.apiVersion' '$AUTHN')\" == apiserver.config.k8s.io/v1 && \"\$(yq '.kind' '$AUTHN')\" == AuthenticationConfiguration &&
       \"\$(yq -o=json -I=0 'keys' '$AUTHN')\" == '[\"apiVersion\",\"kind\",\"jwt\"]' ]]"
  check "恰 1 个 JWT 发行方；issuer 与 audience 等于常量；无 discoveryURL / certificateAuthority / audienceMatchPolicy" bash -c "
    [[ \"\$(yq '.jwt | length' '$AUTHN')\" == 1 &&
       \"\$(yq -o=json -I=0 '.jwt[0].issuer' '$AUTHN')\" == '{\"url\":\"$PROBE_OIDC_ISSUER\",\"audiences\":[\"$PROBE_OIDC_AUDIENCE\"]}' ]]"
  want_rules="$(jq -nc --arg repo "$PROBE_OIDC_REPOSITORY" --arg rid "$PROBE_OIDC_REPOSITORY_ID" --arg oid "$PROBE_OIDC_OWNER_ID" \
    --arg wf "$PROBE_OIDC_WORKFLOW_REF" --arg env "$PROBE_OIDC_ENVIRONMENT" --arg sub "$PROBE_OIDC_SUB" '[
    "claims.repository == '\''\($repo)'\''",
    "claims.repository_id == '\''\($rid)'\''",
    "claims.repository_owner_id == '\''\($oid)'\''",
    "claims.job_workflow_ref == '\''\($wf)'\''",
    "claims.ref == '\''refs/heads/main'\''",
    "claims.environment == '\''\($env)'\''",
    "claims.sub == '\''\($sub)'\''",
    "claims.runner_environment == '\''github-hosted'\''",
    "claims.event_name in ['\''push'\'', '\''schedule'\'', '\''workflow_dispatch'\'']",
    "claims.exp - claims.iat <= 86400"] | sort')"
  got_rules="$(j '[.jwt[0].claimValidationRules[].expression] | sort' "$AUTHN")"
  [[ "$got_rules" == "$want_rules" ]] && pass "claimValidationRules 恰为 ADR 0057 §4.1 的 10 条（逐字）" ||
    fail "claimValidationRules" "$(jq -nc --argjson g "$got_rules" --argjson w "$want_rules" '{missing: ($w - $g), extra: ($g - $w)}')"
  check "每条 claim 规则都有 message，且不用 claim/requiredValue 简写" bash -c "
    [[ \"\$(yq '[.jwt[0].claimValidationRules[] | select((.message // \"\") == \"\" or has(\"claim\") or has(\"requiredValue\"))] | length' '$AUTHN')\" == 0 ]]"
  check "username 映射逐字：'github-actions:' + claims.repository + ':' + claims.environment" bash -c "
    [[ \"\$(yq -o=json -I=0 '.jwt[0].claimMappings.username' '$AUTHN')\" == '{\"expression\":\"'\\''github-actions:'\\'' + claims.repository + '\\'':'\\'' + claims.environment\"}' ]]"
  check "claimMappings 只有 username 与 extra（不映射 groups / uid）" bash -c "
    [[ \"\$(yq -o=json -I=0 '.jwt[0].claimMappings | keys' '$AUTHN')\" == '[\"username\",\"extra\"]' ]]"
  want_extra='[{"key":"aster-lang.dev/gha-actor","valueExpression":"claims.actor"},{"key":"aster-lang.dev/gha-event","valueExpression":"claims.event_name"},{"key":"aster-lang.dev/gha-jti","valueExpression":"claims.jti"},{"key":"aster-lang.dev/gha-run-attempt","valueExpression":"claims.run_attempt"},{"key":"aster-lang.dev/gha-run-id","valueExpression":"claims.run_id"},{"key":"aster-lang.dev/gha-sha","valueExpression":"claims.sha"}]'
  [[ "$(j '.jwt[0].claimMappings.extra | sort_by(.key)' "$AUTHN")" == "$want_extra" ]] && pass "extra 恰为 6 个 aster-lang.dev/gha-* 审计字段" ||
    fail "extra" "$(j '.jwt[0].claimMappings.extra' "$AUTHN")"
  want_user="$(jq -nc --arg u "$PROBE_OIDC_USER" '["!user.username.startsWith('\''system:'\'')", "user.username == '\''\($u)'\''", "user.groups.all(g, !g.startsWith('\''system:'\'') || g == '\''system:authenticated'\'')"] | sort')"
  [[ "$(j '[.jwt[0].userValidationRules[].expression] | sort' "$AUTHN")" == "$want_user" ]] &&
    pass "userValidationRules：禁 system: 前缀、用户名恰为常量、除 system:authenticated 外无 system: 组" ||
    fail "userValidationRules" "$(j '.jwt[0].userValidationRules' "$AUTHN")"
fi

echo "== apiserver drop-in"
if [[ ! -s "$DROP_AUDIT" || ! -s "$DROP_OIDC" ]]; then fail "两个 drop-in 存在"; else
  want_audit='["audit-policy-file=/etc/rancher/k3s/aster/audit-policy.yaml","audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log","audit-log-format=json","audit-log-maxage=30","audit-log-maxbackup=20","audit-log-maxsize=100","audit-log-compress=true"]'
  [[ "$(j '.' "$DROP_AUDIT")" == "{\"kube-apiserver-arg+\":$want_audit}" ]] &&
    pass "50-aster-audit：只有 kube-apiserver-arg+（追加），取值恰为 ADR 0057 D6" || fail "50-aster-audit" "$(j '.' "$DROP_AUDIT")"
  [[ "$(j '.' "$DROP_OIDC")" == '{"kube-apiserver-arg+":["authentication-config=/etc/rancher/k3s/aster/authentication-config.yaml"]}' ]] &&
    pass "60-aster-oidc：只有 kube-apiserver-arg+，指向认证配置" || fail "60-aster-oidc" "$(j '.' "$DROP_OIDC")"
  check "drop-in 引用的文件都在 bundle 里" bash -c "
    [[ -s '$F/aster/audit-policy.yaml' && -s '$F/aster/authentication-config.yaml' ]]"
  check "drop-in 不含 oidc-* 旧参数（与 --authentication-config 互斥，apiserver 会直接退出）" bash -c "! grep -hv '^[[:space:]]*#' '$DROP_AUDIT' '$DROP_OIDC' | grep -q 'oidc-'"
fi

echo "== 身份跨文件一致"
pairs="$(jq -nc --arg sa "$PROBE_SA_USER" --arg oidc "$PROBE_OIDC_USER" '[$sa, $oidc] | sort')"
[[ "$(j '[.rules[] | select(.users) | .users | select(any_c(. == "'"$PROBE_SA_USER"'"))] | map(sort) | unique' "$AUDIT")" == "[$pairs]" ]] &&
  pass "审计策略：凡列探针身份的规则都恰列 {SA, OIDC}" || fail "审计策略的探针身份" "$(j '[.rules[] | select(.users) | .users]' "$AUDIT")"
manif="$(mktemp)"; trap 'rm -f "$manif"' EXIT
for d in apps/aster-lang/agents apps/aster-lang/guard apps/aster-lang/tools apps/infrastructure/guard-admission; do
  kustomize build "$ROOT/$d" | yq -o=json -I=0 'select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding" or .kind == "ValidatingAdmissionPolicy")' >>"$manif"
done
want_subjects="$(jq -nc --arg u "$PROBE_OIDC_USER" '[{kind: "ServiceAccount", name: "guard-bypass-probe", namespace: "aster-guard"}, {apiGroup: "rbac.authorization.k8s.io", kind: "User", name: $u}]')"
bad="$(jq -sc --argjson w "$want_subjects" '[.[] | select(.kind != "ValidatingAdmissionPolicy") | select((.subjects | sort_by(.kind)) != $w) | .metadata.name]' "$manif")"
n="$(jq -s '[.[] | select(.kind != "ValidatingAdmissionPolicy")] | length' "$manif")"
[[ "$bad" == "[]" && "$n" == 4 ]] && pass "4 条探针绑定的 subjects 恰为 {SA, OIDC User}" || fail "探针绑定 subjects" "绑定数 ${n}，不符：$bad"
want_mc="request.userInfo.username in ['$PROBE_SA_USER', '$PROBE_OIDC_USER']"
[[ "$(jq -sr '.[] | select(.kind == "ValidatingAdmissionPolicy" and .metadata.name == "guard-probe-pod-scope") | .spec.matchConditions[0].expression' "$manif")" == "$want_mc" ]] &&
  pass "guard-probe-pod-scope 的 matchConditions 恰匹配两个探针身份" || fail "VAP matchConditions"
check "工作流的 OIDC audience / 身份常量来自 lib.sh（不在工作流里另写一份）" bash -c "
  ! grep -v '^[[:space:]]*#' '$WF' | grep -qE 'k3s-guard-probe|github-actions:wontlost-ltd'"

if [[ "$FAILED" != 0 ]]; then echo "authn-config.test.sh：有用例失败" >&2; exit 1; fi
echo "authn-config.test.sh：全部通过"
