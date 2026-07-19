# policy-controller（S2-0 cosign admission）运维手册

设计：`docs/p0a-s2-0-cosign-admission-design.md`。★S2-0 是 artifact-deployment
policy，**不解锁签字、非 runtime binding 证明**。

## 启用（贴 namespace 标签 = opt-in 主闸）

policy-controller 只拦贴 `policy.sigstore.dev/include=true` 的 namespace。首版只启用 aster-cloud：

    kubectl label namespace aster-cloud policy.sigstore.dev/include=true

★**贴标签前先过 admission smoke-test**（确认 apiserver 能调 webhook；wave 健康门只保证 CRD established + controller Deployment Ready，不保证 webhook 端到端可调）：

    # 在 aster-cloud 提交一个已知已签 digest 的临时 pod，确认放行；提交未签的，确认被拒（enforce）。

## 标签监控（★手工标签的静默失效风险）

namespace 重建后标签消失 → S2-0 静默关闭。必须配告警：

    # 定期断言标签存在，缺失即告警（示例，接入现有 Prometheus/alert）：
    kubectl get ns aster-cloud -o jsonpath='{.metadata.labels.policy\.sigstore\.dev/include}' | grep -q true \
      || echo "ALERT: aster-cloud 缺 policy.sigstore.dev/include 标签，S2-0 已静默关闭"

## failurePolicy 阶段化（首版 Ignore → 达门槛切 Fail）

首版 `webhookConfig.failurePolicy: Ignore`（webhook 故障时放行，避免 outage；但故障期未签镜像会被静默放行 → 依赖 webhook 可用性告警）。

切 `Fail`（故障态也 fail-closed）的门槛：连续观察 ≥7 天 + webhook 可用率 ≥99.9% + admission p99 延迟/错误率在阈内 + 告警演练成功 + break-glass 演练成功。改 `application.yaml` 的 `webhookConfig.failurePolicy: Fail` 并 sync。

## Break-glass 回滚（顺序严格）

1. **摘 opt-in 标签**（唯一 outage-无关的可靠 break-glass，秒级）：

       kubectl label namespace aster-cloud policy.sigstore.dev/include-

2. **临时把两类 webhook 的 failurePolicy 改 Ignore，或删 4 个 webhook config**（chart 出 2 Validating + 2 Mutating；tag→digest 靠 Mutating）——删 backend 前先解除 fail-closed。
3. 从 ApplicationSet/Git 移除 policy-controller 元素或暂停自动同步（否则 selfHeal 重建）。
4. 删 controller、4 个 CIP、2 个 CRD（`clusterimagepolicies` / `trustroots`）。
5. 验证无残留 Validating/Mutating WebhookConfiguration。

★危险点：直接删 Application 时若 Deployment/Service 先于 webhook config 被删、webhook 仍 Fail → 新 admission outage。故顺序 2（含 Mutating）必在 3/4 前。

## staging 动态门清单（本地做不了，上线前必跑）

- 真 Fulcio OIDC 跨身份 fixture 负测（ci.yml 身份签 aster-api → 被拒）。
- webhook 端到端 admission smoke-test（apiserver→webhook TLS/endpoint/网络）。
- tag 四态：已签可解析 tag 通过 / 未签可解析 tag 被拒 / 不可解析 tag → tag-fail 拒 / mutation 后 digest 不命中 tag-fail。
- 绕过面：Pod/Deployment/Job/CronJob/StatefulSet/DaemonSet/init container/ephemeral container（`kubectl debug --image=<未签受控仓镜像>`）全被拦。
- wave 0→2 真 ArgoCD sync（CRD established 后才 apply CIP）。
- 回滚演练（按上面顺序，无级联 outage）。

## 信任根漂移守门

改信任根或 CIP 后跑：`./scripts/image-pin/verify-cip-sync.sh`（应 exit 0）。建议接 CI。
