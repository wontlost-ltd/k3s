#!/usr/bin/env bash
# 部署层绕过探针的共享判定（aster-api ADR 0054 §12 D2 / D7；wontlost-ltd/aster-api#466）。
# 只定义函数，供 direct-connect-probe.sh、manifests.test.sh 等 source。依赖 jq。

# policy_union_violations <policies.json> <pod-labels.json> <admit-ns>
#   policies.json  ：`kubectl get networkpolicy -o json` 的结果（List，含 .items）
#   pod-labels.json：工具 Pod 的 metadata.labels（对象）
#   admit-ns       ：唯一允许进入的命名空间（aster-guard）
# stdout 每行一个违规，空即合规。策略是叠加的，所以按「所有选中该 Pod 的策略」的并集判定（R67 D2）：
#   - 至少一条策略选中该 Pod；
#   - 每条选中策略 policyTypes 恰为 [Ingress]，无 egress 规则；
#   - 每条 ingress 规则的 from 非空，且每个 peer 恰为
#     namespaceSelector.matchLabels == {kubernetes.io/metadata.name: <admit-ns>}
#     （无 podSelector / ipBlock / matchExpressions：kube-router 对组合 peer 有缺陷，见 cloudflare-tunnel 注释）；
#   - 每条规则 ports 恰为 8080/TCP（缺 ports 即放行全部端口）。
# 选择器只支持 matchLabels；带 matchExpressions 的 podSelector 无法离线判定，按违规报告（宁可误报）。
policy_union_violations() {
  local policies="$1" labels="$2" admit="$3"
  jq -r --slurpfile labels "$labels" --arg admit "$admit" '
    def selects($l):
      (.spec.podSelector // {}) as $s
      | if ($s.matchExpressions // []) | length > 0 then "unsupported"
        else (($s.matchLabels // {}) | to_entries | all(. as $e | $l[$e.key] == $e.value))
        end;
    def peer_ok:
      (keys == ["namespaceSelector"])
      and ((.namespaceSelector | keys) == ["matchLabels"])
      and (.namespaceSelector.matchLabels == {"kubernetes.io/metadata.name": $admit});
    def ports_ok:
      (.ports // []) as $p
      | ($p | length) == 1
        and (($p[0].protocol // "TCP") == "TCP")
        and ($p[0].port == 8080)
        and (($p[0] | keys) - ["protocol", "port"] | length == 0);
    $labels[0] as $l
    | [(.items // [])[] | . as $p | {name: .metadata.name, sel: selects($l), p: $p}] as $all
    | ($all | map(select(.sel == "unsupported")) | .[] | "unsupported_selector \(.name): podSelector 含 matchExpressions，无法离线判定"),
      (if ($all | map(select(.sel == true)) | length) == 0 then "no_policy: 没有任何 NetworkPolicy 选中工具 Pod" else empty end),
      ($all | map(select(.sel == true)) | .[] | .name as $n | .p.spec as $s
        # 缺省 policyTypes 的语义：恒含 Ingress，有 egress 字段时另含 Egress（k8s API 文档）。
        | ($s.policyTypes // (["Ingress"] + (if $s.egress != null then ["Egress"] else [] end))) as $types
        | (if ($types | sort) != ["Ingress"] then "policy_types \($n): 生效的 policyTypes 须恰为 [Ingress]，实为 \($types)" else empty end),
          (if ($s.egress // null) != null then "egress \($n): 不得有 egress 规则" else empty end),
          (($s.ingress // []) | to_entries[] | .key as $i | .value
            | (if (.from // []) | length == 0 then "empty_from \($n)[\($i)]: from 为空即放行所有来源" else empty end),
              ((.from // [])[] | select(peer_ok | not) | "bad_peer \($n)[\($i)]: peer 须恰为 namespaceSelector {kubernetes.io/metadata.name: \($admit)}，实为 \(tojson)"),
              (if ports_ok then empty else "bad_ports \($n)[\($i)]: ports 须恰为 8080/TCP，实为 \(.ports // "全部端口" | tojson)" end)))
  ' "$policies"
}

# classify_curl <curl 退出码> <http_code>
#   7（连接被拒）/ 28（超时）→ blocked；0（收到任何 HTTP 响应，含 401）→ reachable；
#   6（DNS 解析失败）及其它 → inconclusive（不能把「坏了」当成「挡住了」，R67 D7）。
classify_curl() {
  local rc="$1"
  case "$rc" in
    7|28) echo blocked ;;
    0) echo reachable ;;
    *) echo inconclusive ;;
  esac
}

# jwt_claims：从 stdin 读一个 JWT，stdout 输出其 payload（JSON）。只解码不验签——用途是检查 TokenRequest
# 签发结果的 exp / iat（签名由 API server 校验）。token 本身不回显。
jwt_claims() {
  local payload pad
  payload="$(cut -d. -f2 | tr '_-' '/+')"
  pad=$(( (4 - ${#payload} % 4) % 4 ))
  printf '%s%s' "$payload" "$(printf '%*s' "$pad" '' | tr ' ' '=')" | base64 -d 2>/dev/null
}

# 探针凭证的有效期上限：90 天 + 1 小时（TokenRequest 的签发结果可能比请求值长，见计划 §3）。
# shellcheck disable=SC2034  # 供 source 方（token-expiry.sh、kubeconfig-for-probe.sh）使用
PROBE_TOKEN_MAX_LIFETIME=$((90 * 86400 + 3600))
