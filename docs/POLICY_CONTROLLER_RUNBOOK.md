# policy-controller（S2-0 cosign admission）运维手册

设计：`docs/p0a-s2-0-cosign-admission-design.md`。★S2-0 是 artifact-deployment
policy，**不解锁签字、非 runtime binding 证明**。

## 启用（贴 namespace 标签 = opt-in 主闸）

policy-controller 只拦贴 `policy.sigstore.dev/include=true` 的 namespace。首版只启用 aster-cloud。

★**贴标签前必须先在临时测试 namespace 里跑完整 admission smoke-test**（wave 健康门只保证
CRD established + controller Deployment Ready，**不保证** webhook 端到端可调；而且如果直接
在**未贴标签**的 aster-cloud 里提交测试 pod，namespace opt-in 主闸未打开、webhook 根本不会
被调用——已签/未签镜像都会放行，测出来的是「假绿」，不代表 enforce 生效）。

### Smoke-test 步骤（临时 namespace，六态齐验）

1. 建一个**临时的、已贴标签**的测试 namespace（不要复用 aster-cloud，避免在验证阶段就把真实
   workload 暴露给未经验证的 webhook 配置）：

       kubectl create namespace s2-admission-smoke
       kubectl label namespace s2-admission-smoke policy.sigstore.dev/include=true

2. 在 `s2-admission-smoke` 里依次提交六态测试 pod，**每一态都要检查 admission 响应
   （`kubectl apply` 的 stderr/exit code，或 `kubectl get events`）或最终 PodSpec 落地的镜像
   引用，不能只看 Pod 是否变成 Running**（Running 不能证明 admission 真的拦截了——如果 webhook
   没生效，未签镜像一样能 Running）：

   | # | 场景 | 镜像形态 | 预期 admission 结果 |
   |---|------|----------|----------------------|
   | 1 | 已签 digest | `docker.io/wontlost/aster-api@sha256:<已签摘要>` | 通过（cosign 验签成功） |
   | 2 | 未签 digest | `docker.io/wontlost/aster-api@sha256:<未签摘要>` | 拒绝（enforce，digest-verify CIP 命中） |
   | 3 | 已签可解析 tag | `docker.io/wontlost/aster-api:<已签 tag>` | 通过（mutation 解析成 digest 后命中 digest-verify CIP，验签成功） |
   | 4 | 未签可解析 tag | `docker.io/wontlost/aster-api:<未签 tag>` | 拒绝（mutation 解析成 digest 后命中 digest-verify CIP，验签失败） |
   | 5 | 不存在/不可解析 tag | `docker.io/wontlost/aster-api:<不存在的 tag>` | 拒绝（`resolveDigest` 失败保留 `repo:tag` 形态，命中 tag-fail CIP，无条件拒，闭 TOCTOU） |
   | 6 | 不匹配受控仓的镜像 | 任意不在信任根里的第三方镜像 | 放行（`no-match-policy: allow`，灰度副闸；不代表验签通过，只是未纳管） |

   六态全部与预期一致才算 smoke-test 通过。

3. 通过后清理临时 namespace：

       kubectl delete namespace s2-admission-smoke

4. **确认六态全部符合预期之后，再**给 aster-cloud 贴 opt-in 标签：

       kubectl label namespace aster-cloud policy.sigstore.dev/include=true

## 标签监控（★上线前阻塞项——手工标签的静默失效风险，本 PR 未落地实现）

namespace 重建后标签消失 → S2-0 静默关闭，且**不会报错、不会有任何 admission 日志**（webhook
根本不会被调用）。这是**上线前的硬性阻塞项**，本 PR 只诚实标注该缺口，**不提供监控实现**：

- 落地约束（上线前必须满足，缺一不可）：
  - 执行体：一个独立的 CronJob（或等价的 PrometheusRule + 现有 Alertmanager 规则），**不能**
    依赖 policy-controller 自身的健康信号（controller 健康不代表标签还在）。
  - 检查周期：≤5 分钟一次（标签消失到告警触发的窗口越短，静默关闭的暴露面越小）。
  - 检查内容：至少两类缺失都要单独告警——
    1. `aster-cloud` namespace 本身不存在或被删（比标签缺失更严重，说明整个 opt-in 主体消失）；
    2. namespace 存在但 `policy.sigstore.dev/include` 标签缺失或值不为 `true`。
  - 告警名/渠道：接入现有 Prometheus/Alertmanager（沿用本仓库已有告警接入方式，不新增告警
    通道）；告警名建议 `S2AdmissionOptInLabelMissing`，severity 至少 `warning`（因为故障态是
    静默放行未签镜像，属于安全闸失效，不是单纯的可用性问题）。
  - 验证：告警演练（人为摘标签后确认在检查周期内收到告警）是 §「staging 动态门清单」里已列的
    上线前必跑项，与本节是同一件事的两面（本节定约束，动态门清单定验收）。

在上述监控真正落地并通过告警演练之前，**不能**认为标签的持续有效性有保障；运维只能靠人工
定期用下面的一次性命令自查（**这不是监控，只是本 PR 范围内可给出的临时手工核查手段**）：

    kubectl get ns aster-cloud -o jsonpath='{.metadata.labels.policy\.sigstore\.dev/include}' | grep -q true \
      || echo "手工核查发现：aster-cloud 缺 policy.sigstore.dev/include 标签，S2-0 已静默关闭（非自动告警，需人工定期执行）"

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
