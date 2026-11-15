#!/usr/bin/env bash
# kube-apiserver 审计策略的离线测试（aster-api ADR 0057 §3；计划 Task 1）。
#
# 用 jq 实现与 k8s staging/src/k8s.io/apiserver/pkg/audit/policy/checker.go 同语义的求值器（首条命中；资源按
# 「resource/subresource」组合匹配，支持 "*"、"*/sub"、"res/*"；非资源 URL 支持 "*" 后缀前缀匹配；
# namespaces 对集群级资源取 ""），再以请求表断言级别——断言的是**行为**（某类请求最终记成什么），不是规则顺序。
# 用法：bash hosts/k3s-server/audit-policy.test.sh；依赖 yq（mikefarah v4）与 jq。
# shellcheck disable=SC2015  # pass 恒成功，A && pass || fail 即 if-else
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_YAML="$HERE/files/etc/rancher/k3s/aster/audit-policy.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1${2:+：$2}"; FAILED=1; }

SA=system:serviceaccount:aster-guard:guard-bypass-probe
OIDC=github-actions:wontlost-ltd/k3s:guard-probe

if [[ ! -s "$POLICY_YAML" ]]; then
  fail "策略文件存在" "$POLICY_YAML"
  echo "audit-policy.test.sh：有用例失败" >&2
  exit 1
fi
yq -o=json '.' "$POLICY_YAML" >"$WORK/policy.json"

# 求值器：stdin 为请求对象，$p 为策略；输出级别（无规则命中时 None，与 apiserver 一致）。
cat >"$WORK/eval.jq" <<'JQ'
def has_or_empty($list; $v): ($list // []) as $l | ($l | length) == 0 or ($l | index($v)) != null;
def path_matches($path; $spec):
  $spec == "*" or $spec == $path
  or (($spec | endswith("*")) and ($path | startswith($spec | rtrimstr("*"))));
def res_matches($r; $q):
  if ($q.resourceRequest | not) then false
  elif (($r.namespaces // []) | length) > 0 and (($r.namespaces | index($q.namespace // "")) == null) then false
  elif (($r.resources // []) | length) == 0 then true
  else
    ($q.resource + (if ($q.subresource // "") != "" then "/" + $q.subresource else "" end)) as $combined
    | any($r.resources[]; . as $gr
        | ($gr.group // "") == ($q.apiGroup // "")
        and ((($gr.resourceNames // []) | length) == 0 or (($gr.resourceNames | index($q.name // "")) != null))
        and ((($gr.resources // []) | length) == 0
             or any($gr.resources[]; . as $res
                 | $res == $combined or $res == "*"
                   or ((($q.subresource // "") != "") and ($res | startswith("*/")) and ($q.subresource == ($res | ltrimstr("*/"))))
                   or (($res | endswith("/*")) and ($q.resource == ($res | rtrimstr("/*")))))))
  end;
def nonres_matches($r; $q):
  if $q.resourceRequest then false else any(($r.nonResourceURLs // [])[]; path_matches($q.path; .)) end;
def rule_matches($r; $q):
  has_or_empty($r.users; $q.user)
  and ((($r.userGroups // []) | length) == 0 or any(($q.groups // [])[]; . as $g | ($r.userGroups | index($g)) != null))
  and has_or_empty($r.verbs; $q.verb)
  and (if (($r.namespaces // []) | length) > 0 or (($r.resources // []) | length) > 0 then res_matches($r; $q)
       elif (($r.nonResourceURLs // []) | length) > 0 then nonres_matches($r; $q)
       else true end);
. as $q | [$p.rules[] | select(rule_matches(.; $q)) | .level] | first // "None"
JQ

# req <user> <groups-csv> <verb> <group/resource[/sub]> <namespace> → 请求 JSON（资源请求）
req() {
  local user="$1" groups="$2" verb="$3" gr="$4" ns="$5" group res sub=""
  group="${gr%%|*}"; res="${gr#*|}"
  if [[ "$res" == */* ]]; then sub="${res#*/}"; res="${res%%/*}"; fi
  jq -nc --arg u "$user" --arg g "$groups" --arg v "$verb" --arg ag "$group" --arg r "$res" --arg s "$sub" --arg ns "$ns" \
    '{user: $u, groups: ($g | split(",") | map(select(. != ""))), verb: $v, resourceRequest: true,
      apiGroup: $ag, resource: $r, subresource: $s, namespace: $ns, name: "x"}'
}
nonres() { jq -nc --arg u "$1" --arg v "$2" --arg p "$3" '{user: $u, groups: [], verb: $v, resourceRequest: false, path: $p}'; }
level() { jq -r --slurpfile p "$WORK/policy.json" '$p[0] as $p | '"$(cat "$WORK/eval.jq")"; }
lvl() { level <<<"$1"; }
rank() { case "$1" in None) echo 0 ;; Metadata) echo 1 ;; Request) echo 2 ;; RequestResponse) echo 3 ;; *) echo 9 ;; esac; }

# expect <用例名> <期望级别> <请求 JSON>...：全部请求都须得到期望级别
expect() {
  local name="$1" want="$2" got bad=""; shift 2
  for q in "$@"; do got="$(lvl "$q")"; [[ "$got" == "$want" ]] || bad+=" $(jq -c '{user,verb,apiGroup,resource,subresource,namespace,path}' <<<"$q")→$got"; done
  if [[ -z "$bad" ]]; then pass "$name"; else fail "$name" "$bad"; fi
}

echo "== 求值器自检（与 checker.go 同语义）"
cat >"$WORK/mini.json" <<'JSON'
{"rules":[
 {"level":"Request","resources":[{"group":"","resources":["pods"]}]},
 {"level":"RequestResponse","resources":[{"group":"","resources":["*/status"]}]},
 {"level":"Metadata","resources":[{"group":"apps","resources":["deployments/*"]}]},
 {"level":"Request","namespaces":[""],"resources":[{"group":""}]},
 {"level":"Metadata","nonResourceURLs":["/healthz*"]}
]}
JSON
mini() { jq -r --slurpfile p "$WORK/mini.json" '$p[0] as $p | '"$(cat "$WORK/eval.jq")" <<<"$1"; }
r1="$(mini "$(req u '' get '|pods/log' ns1)")"; r2="$(mini "$(req u '' get '|pods' ns1)")"
r3="$(mini "$(req u '' patch '|nodes/status' '')")"; r4="$(mini "$(req u '' get 'apps|deployments/scale' ns1)")"
r5="$(mini "$(req u '' get '|namespaces' '')")"; r6="$(mini "$(req u '' get '|services' ns1)")"
r7="$(mini "$(nonres u get /healthz/etcd)")"; r8="$(mini "$(nonres u get /livez)")"
if [[ "$r1 $r2 $r3 $r4 $r5 $r6 $r7 $r8" == "None Request RequestResponse Metadata Request None Metadata None" ]]; then
  pass "evaluator_semantics（pods≠pods/log、*/status、res/*、namespaces [\"\"]、/healthz* 前缀）"
else fail evaluator_semantics "$r1 $r2 $r3 $r4 $r5 $r6 $r7 $r8"; fi

echo "== 形状"
[[ "$(jq -r '.apiVersion + " " + .kind' "$WORK/policy.json")" == "audit.k8s.io/v1 Policy" ]] && pass "apiVersion audit.k8s.io/v1 Policy" || fail "apiVersion"
[[ "$(jq -c '.omitStages' "$WORK/policy.json")" == '["RequestReceived"]' && "$(jq '.omitManagedFields' "$WORK/policy.json")" == true ]] &&
  pass "omitStages [RequestReceived]、omitManagedFields" || fail "omitStages / omitManagedFields"
[[ "$(jq '[.rules[].level | select(IN("None","Metadata","Request","RequestResponse") | not)] | length' "$WORK/policy.json")" == 0 ]] &&
  pass "每条规则级别合法" || fail "非法级别"
[[ "$(jq -c '.rules[-1]' "$WORK/policy.json")" == '{"level":"Metadata"}' ]] && pass "最后一条为无条件 Metadata" || fail "兜底规则" "$(jq -c '.rules[-1]' "$WORK/policy.json")"
[[ "$(jq '[.rules[] | select(.omitStages)] | length' "$WORK/policy.json")" == 0 ]] && pass "规则不覆盖全局 omitStages" || fail "规则级 omitStages"

echo "== 敏感资源永不高于 Metadata"
SENS=('|secrets' '|configmaps' '|serviceaccounts/token' 'authentication.k8s.io|tokenreviews')
WHO=("$SA|" "$OIDC|" "kubernetes-admin|system:masters" "system:kube-controller-manager|" "system:node:master-1|system:nodes" "system:serviceaccount:argocd:argocd-application-controller|system:serviceaccounts")
bad=""
for gr in "${SENS[@]}"; do for w in "${WHO[@]}"; do for v in get list watch create update patch delete; do
  q="$(req "${w%%|*}" "${w#*|}" "$v" "$gr" aster-agents)"; got="$(lvl "$q")"
  (( $(rank "$got") <= 1 )) || bad+=" ${w%%|*}:$v:${gr}→$got"
done; done; done
[[ -z "$bad" ]] && pass "sensitive_never_above_metadata（4 类 × 6 身份 × 7 verb）" || fail sensitive_never_above_metadata "$bad"
expect "敏感资源对探针身份仍记 Metadata（不被噪声规则吞掉）" Metadata \
  "$(req "$SA" '' get '|secrets' aster-agents)" "$(req "$OIDC" '' create '|serviceaccounts/token' aster-guard)" \
  "$(req "$SA" '' watch '|configmaps' aster-agents)"

echo "== 探针身份总被记录"
bad=""
for u in "$SA" "$OIDC"; do
  for gr in '|pods' '|pods/log' 'coordination.k8s.io|leases' '|events' '|namespaces' 'apps|deployments' 'rbac.authorization.k8s.io|rolebindings'; do
    for v in get list watch create delete; do
      q="$(req "$u" system:authenticated "$v" "$gr" aster-agents)"; got="$(lvl "$q")"
      case "$v" in create|delete) want=RequestResponse ;; *) want=Metadata ;; esac
      [[ "$got" == "$want" ]] || bad+=" $u:$v:${gr}→${got}(期望 $want)"
    done
  done
  for v in update patch deletecollection; do
    got="$(lvl "$(req "$u" '' "$v" '|pods' aster-agents)")"; [[ "$got" == RequestResponse ]] || bad+=" $u:$v:pods→$got"
  done
done
[[ -z "$bad" ]] && pass "probe_identities_always_logged（写入 RequestResponse，读 / watch / 越权尝试 Metadata）" || fail probe_identities_always_logged "$bad"
expect "探针的非资源请求（discovery）也记 Metadata" Metadata "$(nonres "$SA" get /apis)" "$(nonres "$OIDC" get /api/v1)"

echo "== 噪声排除"
expect lease_heartbeat_dropped None \
  "$(req system:node:master-1 system:nodes update 'coordination.k8s.io|leases' kube-node-lease)" \
  "$(req system:kube-controller-manager '' get 'coordination.k8s.io|leases' kube-system)" \
  "$(req system:serviceaccount:argocd:argocd-application-controller system:serviceaccounts update 'coordination.k8s.io|leases' argocd)"
expect lease_create_delete_kept Metadata \
  "$(req kubernetes-admin system:masters delete 'coordination.k8s.io|leases' kube-system)" \
  "$(req system:serviceaccount:x:y '' create 'coordination.k8s.io|leases' x)"
expect event_writes_dropped None \
  "$(req system:node:master-1 system:nodes create '|events' aster-agents)" \
  "$(req system:kube-scheduler '' patch 'events.k8s.io|events' default)"
expect event_reads_kept Metadata "$(req kubernetes-admin system:masters list '|events' aster-agents)"
expect system_reads_dropped None \
  "$(req system:kube-controller-manager '' get '|endpoints' default)" \
  "$(req system:k3s-controller '' list '|nodes' '')" \
  "$(req system:kube-proxy '' get 'discovery.k8s.io|endpointslices' default)" \
  "$(req system:node:worker-1 system:nodes get '|pods' aster-agents)" \
  "$(req k3s-cloud-controller-manager '' list '|services' '')" \
  "$(req kube-apiserver '' get '|namespaces' '')" \
  "$(req system:serviceaccount:monitoring:prometheus system:monitoring get '|nodes/metrics' '')"
expect system_writes_kept Metadata \
  "$(req system:kube-controller-manager '' update 'apps|replicasets' aster-cloud)" \
  "$(req system:node:master-1 system:nodes patch '|nodes/status' '')"
expect others_watch_dropped None \
  "$(req kubernetes-admin system:masters watch '|pods' aster-agents)" \
  "$(req system:serviceaccount:argocd:argocd-application-controller system:serviceaccounts watch 'apps|deployments' aster-cloud)"
expect health_and_discovery_dropped None \
  "$(nonres system:anonymous get /healthz)" "$(nonres system:anonymous get /readyz/etcd)" "$(nonres x get /livez)" \
  "$(nonres x get /version)" "$(nonres system:serviceaccount:monitoring:prometheus get /metrics)" \
  "$(nonres x get /api)" "$(nonres x get /apis/apps/v1)" "$(nonres x get /openapi/v3)" \
  "$(nonres system:anonymous get /.well-known/openid-configuration)" "$(nonres system:anonymous get /openid/v1/jwks)"

echo "== 高价值写入"
expect agents_pod_writes_request_response RequestResponse \
  "$(req kubernetes-admin system:masters create '|pods' aster-agents)" \
  "$(req system:serviceaccount:aster-runner:launcher system:serviceaccounts delete '|pods' aster-agents)" \
  "$(req kubernetes-admin system:masters patch '|pods/ephemeralcontainers' aster-agents)" \
  "$(req system:serviceaccount:x:y '' create '|pods/eviction' aster-agents)"
expect "aster-agents 之外的 Pod 写入与 pods/status 只记 Metadata" Metadata \
  "$(req kubernetes-admin system:masters create '|pods' aster-cloud)" \
  "$(req system:node:master-1 system:nodes patch '|pods/status' aster-agents)" \
  "$(req system:kube-scheduler '' create '|pods/binding' aster-agents)"
expect "aster-agents 的 exec / attach / portforward 记 Metadata（不记流）" Metadata \
  "$(req kubernetes-admin system:masters create '|pods/exec' aster-agents)" \
  "$(req kubernetes-admin system:masters get '|pods/portforward' aster-agents)"
bad=""
for gr in 'rbac.authorization.k8s.io|roles' 'rbac.authorization.k8s.io|rolebindings' 'rbac.authorization.k8s.io|clusterroles' 'rbac.authorization.k8s.io|clusterrolebindings' \
          'admissionregistration.k8s.io|validatingadmissionpolicies' 'admissionregistration.k8s.io|validatingadmissionpolicybindings' \
          'admissionregistration.k8s.io|validatingwebhookconfigurations' 'admissionregistration.k8s.io|mutatingwebhookconfigurations'; do
  for v in create update patch delete deletecollection; do
    got="$(lvl "$(req system:serviceaccount:argocd:argocd-application-controller system:serviceaccounts "$v" "$gr" aster-agents)")"
    [[ "$got" == RequestResponse ]] || bad+=" $v:${gr}→$got"
  done
done
[[ -z "$bad" ]] && pass "rbac_and_admission_writes_request_response" || fail rbac_and_admission_writes_request_response "$bad"
expect "RBAC / 准入的读记 Metadata（非系统身份）" Metadata \
  "$(req kubernetes-admin system:masters get 'rbac.authorization.k8s.io|rolebindings' aster-agents)" \
  "$(req kubernetes-admin system:masters list 'admissionregistration.k8s.io|validatingadmissionpolicies' '')"

echo "== 兜底"
expect catch_all_metadata Metadata \
  "$(req kubernetes-admin system:masters get 'apps|deployments' aster-cloud)" \
  "$(req system:serviceaccount:argocd:argocd-application-controller system:serviceaccounts patch 'argoproj.io|applications' argocd)" \
  "$(req kubernetes-admin system:masters create 'authorization.k8s.io|subjectaccessreviews' '')" \
  "$(nonres kubernetes-admin get /logs)"

if [[ "$FAILED" != 0 ]]; then echo "audit-policy.test.sh：有用例失败" >&2; exit 1; fi
echo "audit-policy.test.sh：全部通过"
