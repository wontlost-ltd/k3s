# 提案：把 Vault internal CA 分发到消费方 namespace，消除 `curl -k`

**状态**：待评审
**关联**：k3s#487（第一项）
**日期**：2026-08-30
**影响面**：集群级基础设施（新增一个 operator）+ 1 个脚本 5 处调用

---

## 1. 问题

`apps/infrastructure/secret-rotation/rotate-pg-password.sh` 对 Vault 的
**全部 5 处** curl 都带 `-k`（跳过 TLS 证书校验）：

| 行号 | 用途 |
|---|---|
| 36 | Kubernetes auth 换 Vault token |
| 44 | 读 Cloudflare API token |
| 77 | 读当前 PG 凭据（KV-v2） |
| 88 | 写新密码（重试循环内） |
| 103 | 写回完整 KV-v2 数据 |

即**新 PG 密码、旧密码、Cloudflare API token 三者都在不验证对端身份的连接上收发**。

★同一脚本对 Cloudflare API 的两处 curl（`:58` `:161`）**没有** `-k` ——
说明这不是全局习惯，而是专门为 Vault 自签证书加的临时手段。
「同类调用在同一文件里不一致」是识别临时手段的可靠信号。

### 攻击面（如实评估，不夸大）

调用发生在 **Pod → Service ClusterIP** 的集群内路径上，攻击者需要先具备
「能在 `secret-rotation` → `vault` 之间做中间人」的位置，例如：
- 攻陷同集群另一 Pod 并具备 CNI 层重定向能力
- 或攻陷 kube-proxy / CNI 组件本身

这不是"任何人都能利用"的漏洞，故 issue 定级 Medium 是合适的。
但 `-k` 让**上述任一前提成立时**的后果从"看到加密流量"变成"拿到明文凭据"，
而这些凭据的爆炸半径是生产数据库 + Cloudflare 账户。

---

## 2. 为什么不能直接改成 `--cacert`

issue 的建议是「挂载仓内已有的 `apps/infrastructure/vault/internal-tls.yaml`」。
**实测做不到**，三重阻断：

| 障碍 | 实证 |
|---|---|
| Secret 不跨 namespace | `vault-internal-ca` 在 **vault** ns（`internal-tls.yaml:21`），CronJob 在 **secret-rotation** ns（`cronjob.yaml:10`）。K8s 的 Secret 挂载不跨 ns |
| Issuer 是 namespaced | `vault-internal-ca-issuer` 是 `kind: Issuer`（`:39-41`）不是 ClusterIssuer，别的 ns 引用不到，无法在本 ns 就地再签一份 |
| ExternalSecret 鸡生蛋 | ESO 自己就需要该 CA 才能连 Vault（`vault-secretstore.yaml:30-34` 的 `caProvider`），不能用它去取 CA |

---

## 3. 三个方案

### 方案 A：trust-manager（推荐）

cert-manager 官方的 CA 分发组件，与本仓既有栈同源。

```yaml
# 新增 apps/infrastructure/trust-manager/application.yaml（ArgoCD + Helm）
# 新增 Bundle：把 vault ns 的 CA 分发成各 ns 的 ConfigMap
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: vault-internal-ca
spec:
  sources:
    - secret:
        name: vault-internal-ca
        key: ca.crt
  target:
    configMap:
      key: ca.crt
    namespaceSelector:
      matchLabels:
        vault-ca: "true"          # 显式 opt-in，不广播到全集群
```

CronJob 侧只需挂载该 ConfigMap：

```yaml
volumeMounts:
  - name: vault-ca
    mountPath: /etc/vault-ca
    readOnly: true
volumes:
  - name: vault-ca
    configMap:
      name: vault-internal-ca
```

脚本把 5 处 `-k` 换成 `--cacert /etc/vault-ca/ca.crt`。

**优点**
- cert-manager 官方组件，与现有 v1.19.2 兼容，同一 ArgoCD project 管理
- CA 轮换时 Bundle **自动重新分发**，无需人工同步
- 目标 ns 通过 label 显式 opt-in，不会把 CA 广播到全集群
- 分发产物是 **ConfigMap 而非 Secret** —— CA 公钥本就不是机密，
  用 ConfigMap 避免了"把非机密放进 Secret"带来的误导性权限要求

**代价**
- 引入一个新 operator（约 1 个 Deployment，资源占用小）
- 需要新增 ArgoCD Application + sync-wave 排序（须晚于 cert-manager 的 `-10`）

### 方案 B：Reflector / kubernetes-replicator

第三方 operator，靠注解把 Secret 复制到其它 ns。

**优点**：配置最简单（源 Secret 加一个注解即可）
**代价**：
- 引入**非 cert-manager 生态**的第三方 operator，与现有栈不同源
- 复制的是 **Secret**（含 CA 公钥），语义上不如 ConfigMap 准确
- 社区活跃度与 cert-manager 官方组件不在同一量级

### 方案 C：把 `vault-internal-ca-issuer` 改成 ClusterIssuer

改动最小 —— 不引入任何新组件，改 `kind` 即可，然后在 secret-rotation ns
用它签一张证书（顺带拿到 CA）。

**优点**：零新增组件
**代价（这是我不推荐它的原因）**：
- **放宽了该 CA 的签发面**：改成 ClusterIssuer 后，**任何 namespace** 都能
  用这个 CA 签发证书。而这张 CA 是 Vault 的信任根 —— 谁能用它签证书，
  谁就能签出一张让 Vault 客户端信任的服务端证书
- 即为了"读取 CA 公钥"这个只读需求，付出了"授予全集群签发权"的代价，
  权限与需求严重不匹配

---

## 4. 推荐：方案 A

理由按重要性排序：

1. **权限最小**：只分发 CA **公钥**（ConfigMap），不授予任何签发能力。
   方案 C 恰好相反 —— 为读公钥而开放签发权
2. **同源**：cert-manager 官方组件，与已部署的 v1.19.2 同栈，升级路径一致
3. **CA 轮换自动跟进**：`internal-tls.yaml` 的 CA 是 `duration: 87600h`
   （10 年）不常轮换，但一旦轮换，方案 A 自动分发，B/C 都需要人工介入

---

## 5. 改动清单

| # | 文件 | 改动 |
|---|---|---|
| 1 | `apps/infrastructure/trust-manager/application.yaml` | 新增（ArgoCD Application，Helm chart，sync-wave 须晚于 cert-manager 的 `-10`） |
| 2 | `apps/infrastructure/trust-manager/kustomization.yaml` | 新增（★否则 appset glob 发现不到，见下方"已知陷阱"） |
| 3 | `apps/infrastructure/vault/internal-tls.yaml` | 新增 `Bundle` 资源 |
| 4 | `apps/infrastructure/secret-rotation/namespace.yaml` | 加 label `vault-ca: "true"`（opt-in） |
| 5 | `apps/infrastructure/secret-rotation/cronjob.yaml` | 加 volume + volumeMount |
| 6 | `apps/infrastructure/secret-rotation/rotate-pg-password.sh` | 5 处 `-k` → `--cacert /etc/vault-ca/ca.crt` |
| 7 | `apps/infrastructure/external-secrets/README.md:315` | 文档里的 `curl -k` 示例同步更新 |

★第 2 项容易漏：本仓 ArgoCD 的 ApplicationSet 按
`kustomization.yaml` 的存在与否 glob 发现应用。目录里有 yaml 但没有
`kustomization.yaml` 的话会被**无声跳过** —— `aster-lsp` 至今不在 GitOps
管理下就是这个原因。

---

## 6. 验证步骤（可复跑）

```bash
# 1) trust-manager 就绪
kubectl -n cert-manager get deploy trust-manager -o jsonpath='{.status.readyReplicas}'   # 期望 1

# 2) Bundle 已同步到目标 ns（这一步证明分发真的发生了）
kubectl -n secret-rotation get configmap vault-internal-ca -o jsonpath='{.data.ca\.crt}' | head -1
#    期望：-----BEGIN CERTIFICATE-----

# 3) ★关键：分发的 CA 与源一致（不是"有个文件"就算成功）
diff <(kubectl -n vault get secret vault-internal-ca -o jsonpath='{.data.ca\.crt}' | base64 -d) \
     <(kubectl -n secret-rotation get configmap vault-internal-ca -o jsonpath='{.data.ca\.crt}')
#    期望：无输出

# 4) ★真正的判据：在 CronJob 的**同款镜像 + 同 ns + 同 SA** 里用 --cacert 打 Vault
kubectl -n secret-rotation run ca-probe --rm -i --restart=Never \
  --image=docker.io/alpine/k8s:1.35.6 \
  --overrides='{"spec":{"serviceAccountName":"secret-rotation","volumes":[{"name":"ca","configMap":{"name":"vault-internal-ca"}}],"containers":[{"name":"ca-probe","image":"docker.io/alpine/k8s:1.35.6","volumeMounts":[{"name":"ca","mountPath":"/etc/vault-ca"}],"command":["sh","-c","curl -sS --cacert /etc/vault-ca/ca.crt https://vault.vault.svc.cluster.local:8200/v1/sys/health | head -c 200"]}]}}'
#    期望：返回 Vault health JSON（而非 TLS 错误）

# 5) ★反向验证：不带 --cacert 必须失败——否则说明校验根本没生效
kubectl -n secret-rotation run ca-probe-neg --rm -i --restart=Never \
  --image=docker.io/alpine/k8s:1.35.6 \
  --command -- sh -c 'curl -sS https://vault.vault.svc.cluster.local:8200/v1/sys/health'
#    期望：SSL certificate problem: unable to get local issuer certificate
```

★第 5 步不能省。只验证"带 CA 能通"证明不了校验生效 —— 如果镜像的系统信任库
恰好已包含该 CA，或 curl 因某种原因跳过了校验，第 4 步同样会通过。
必须证明**不带 CA 时会失败**，才能说明第 4 步的成功来自我们挂载的 CA。

---

## 7. 回滚

方案 A 的所有改动都是**加法**（新增组件 + 新增挂载 + 换 curl 参数）：

- 脚本层回滚：`--cacert ...` 改回 `-k`，一行 sed，立即生效
- 组件层回滚：删除 trust-manager Application；Bundle 随之消失，
  已分发的 ConfigMap 会被 GC。**不影响 Vault 本身**，也不影响 ESO
  （它走的是自己的 `caProvider`，与本方案无关）

即回滚不需要碰 Vault、不需要重启任何现有 workload。

---

## 8. 已知陷阱（来自本仓历史）

1. **新增 app 必须带 `kustomization.yaml`** —— 否则 appset glob 发现不到，
   ArgoCD 会**无声跳过**整个目录（`aster-lsp` 的前车之鉴）
2. **sync-wave 排序** —— trust-manager 依赖 cert-manager CRD，
   其 wave 必须晚于 cert-manager 的 `-10`
3. **Synced/Healthy ≠ Pod 在跑** —— 嵌套 Application 会掩盖内层失败，
   验收必须落到第 4/5 步的行为探针上，不能只看 ArgoCD 面板

---

## 9. 本提案未涵盖

- **#487 的第二项（密码经命令行传递）已单独修复**并合并（PR #507）：
  改为 `kubectl exec -i` + stdin 传入，密码不再进 argv / audit log
- Vault 自身的 unseal key 存放问题属 **#488**，与本提案无关
- 本提案不改变 Vault 的证书签发方式，只解决"消费方如何拿到 CA 公钥"
