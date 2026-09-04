# 提案：Vault 迁移到 KMS auto-unseal，消除「key 与密文同处一地」

**状态**：待决策
**关联**：k3s#488（seal 保护实质失效）、k3s#535（本次加固，已处理 CA 验证与明文注解）

---

## 1. 要解决的问题

当前 3 把 unseal key 以普通 K8s Secret 存在**同一个集群**里，CronJob 每 5 分钟自动解封。

seal 的设计目的是「即使拿到存储也读不到数据」。而 key 与密文同处一地时，
**拿到 etcd 快照或节点磁盘的人也就拿到了 key** —— seal 保护对这类攻击者实质失效。

这不是配置疏忽，是自托管 Vault 的**固有取舍**：要么接受它，要么把「解封凭据」
移出本集群的信任域。本提案评估后者。

### 1.1 当前暴露面（2026-09-05 实测，非推断）

| 项 | 结果 |
|---|---|
| 有 ServiceAccount 能读该 Secret 吗 | ⚠️ **19 个**（全集群 SA 穷举，见下） |
| vault 自己的 SA 能读吗 | ❌ 否（`vault-discovery-role` 只有 pods 权限） |
| key 是否进过 git | ❌ 否（工作区 + 全历史均 0 命中） |
| 有备份 CR 覆盖 vault ns 吗 | ❌ 无 velero 类 |
| 有残留明文副本吗 | ❌ 无（managedFields / events / 各类工作负载 spec 全扫） |
| etcd 快照 / 节点磁盘 | ⚠️ **等于拿到 key** ← 本提案要解决的那一条 |

### ★19 个可读 SA（逐个 `auth can-i` 遍历全部 ns）

```
argocd:argocd-application-controller      argocd:argocd-server
cert-manager:cert-manager                 cert-manager:cert-manager-cainjector
cnpg-system:cloudnative-pg                cosign-system:policy-controller-webhook
external-secrets:external-secrets         external-secrets:external-secrets-cert-controller
kube-system:expand-controller             kube-system:generic-garbage-collector
kube-system:helm-traefik                  kube-system:helm-traefik-crd
kube-system:namespace-controller          kube-system:persistent-volume-binder
kube-system:traefik                       monitoring:prometheus-grafana
monitoring:prometheus-kube-prometheus-operator
reflector:reflector                       reloader:reloader-reloader
```

★**这一条我第一版写错了，且错在危险方向**：原文写「❌ 无任何 ServiceAccount
能读」，依据只是抽查了几个 SA。真实数字是 19 个。**抽查得出的"无"不是"无"，
只是"我查的那几个没有"** —— 这类以偏概全会让风险看起来比实际小。

★其中 `prometheus-grafana` / `reloader` / `traefik` / `policy-controller-webhook`
等**与 vault 毫无职能关系**，能读 unseal key 是纯粹的过宽授权。

★**对 #488 原文的订正（收窄版）**：原文说「能读该 Secret 即等于持有解封能力」
—— **成立**。我此前据错误数据推论「实际严重度低于 issue 初判」，**该推论撤回**。
唯一站得住的订正是技术细节：kubelet 解析 `secretKeyRef` **不需要** SA 有
`secrets` 权限（已实证：SA=vault 的 Pod 读该 secret 是 403，但 env 仍注入成功），
故「vault 自己的 SA 不能读」与「解封能正常工作」并不矛盾。

★**已在 #535 处置的一条 issue 未提及的问题**：该 Secret 曾用 `kubectl apply`
创建，`last-applied-configuration` 注解里留了一份完整明文（330 字节），
与 data 字段同样可读。已清除并在清单头部写明须用 `create`。

---

## 2. 现状约束（决定哪些方案是真选项）

实测得到，这些约束直接排除了一半的常见答案：

```
集群       k3s **自管控制面**（providerID=k3s://master-1，非 OKE 托管），
           但**跑在 OCI 计算实例上** —— 这两件事不同，见下方★节点
节点       Oracle Linux Server 9.5 × 4（3 master + 1 worker）
Vault      hashicorp/vault:1.19.0，storage = raft，replicas = 1
云凭据     集群内 0 个 aws/gcp/azure 凭据 Secret
OCI        ★CLI 已配置且实测可用（iam region list / kms vault list 均成功）
           租户 wontlost，当前**尚无** KMS vault
★节点      **确认在 OCI 上** —— compute instance list 实测：
           master one/two/three + worker one，均 VM.Standard.A1.Flex、RUNNING，
           与 k3s 的 3 master + 1 worker 拓扑逐一对应。
           ⇒ **instance principal 可用，无需把任何 API key 放进集群。**
```

★`replicas=1` 是个要点：单副本意味着 Vault 重启即封印，
自动解封不是「优化」而是**可用性刚需** —— 任何方案都不能让解封链路变脆。

---

## 3. 候选方案

### 方案 A：OCI KMS（`ocikms` seal）★推荐

Vault 原生支持 `seal "ocikms"`。密封主密钥托管在 OCI KMS，集群内**不再存任何 unseal key**。

**为什么它在本环境是真选项**：OCI CLI 已配置且实测可用（不是「理论上可以接」）。
节点跑 Oracle Linux，与 OCI 生态同源。

| 维度 | 评估 |
|---|---|
| 消除本问题 | ✅ 彻底 —— 集群内无 key，拿到 etcd 也解不开 |
| 新增依赖 | OCI KMS 可用性成为解封的前置条件 |
| 认证方式 | ✅ **instance principal**（节点已确认在 OCI）—— 无任何长期凭据落盘 |
| 成本 | OCI KMS vault 按小时计费（虚拟私有金库更贵）；密钥操作调用量极小 |
| 迁移可逆性 | ⚠️ 见 §4 —— seal 迁移是**有状态**操作，需停机窗口 |

★**已核实**：节点确在 OCI（见 §2）。故可用 instance principal ——
**集群内不再存任何解封凭据**，方案 A 的收益是完整的，
不存在「把 unseal key 换成 API key」那种打折情形。

★**仍待核实**（实施前确认，非阻塞决策）：
集群到 OCI KMS 端点的网络可达性与延迟（节点在 OCI 内网，预期无碍）。

★**新增前置**：需为节点所在的动态组配 IAM policy，授予
`use key-delegate` / `use keys` 到目标 KMS key。这是**最小权限**授权，
比「集群内一把能解封一切的 unseal key」收敛得多。

### 方案 B：Vault transit auto-unseal（第二个 Vault 解封第一个）

用一个独立 Vault 实例的 transit 引擎解封主 Vault。

| 维度 | 评估 |
|---|---|
| 消除本问题 | ⚠️ **部分** —— 问题变成「谁解封那第二个 Vault」 |
| 新增依赖 | 一个必须独立运维、且**不能与主 Vault 同故障域**的实例 |
| 适用场景 | 多集群/多环境，用一个中心 Vault 解封各环境 |

★**本环境不推荐**：只有一个集群。第二个 Vault 若也跑在这里，
key 仍与密文同处一地，只是多绕一层 —— **看起来解决了，实际没有**。
若跑在集群外，那等于要新建并运维一台机器，成本高于方案 A。

### 方案 C：维持现状 + 补偿控制

不迁移，改为收紧周边：限制能读该 Secret 的主体、加审计告警、定期 rekey。

| 维度 | 评估 |
|---|---|
| 消除本问题 | ❌ 不消除 —— etcd/磁盘那条路径依然通 |
| 成本 | 最低 |
| 适用场景 | 威胁模型里「攻击者能拿到 etcd 快照」被评估为可接受 |

★**订正**：我第一版写「#535 已经把这个方案能做的都做了」—— **不成立**。
那句话建立在「只有 2 个 SA 可读」的错误数据上。真实有 19 个，其中至少
4 个（prometheus-grafana / reloader / traefik / policy-controller-webhook）
与 vault 毫无职能关系。

**方案 C 下尚未动过、且成本远低于 KMS 迁移的一条路**：
收敛这些无关 SA 的集群级 `secrets` 读权限。这不改变「key 与密文同处一地」
这个根本取舍，但**实实在在缩小当前的可达面** —— 从 19 个主体降到必要的少数。

★这条应当**先做**，无论是否迁移 KMS：它是纯收益、无停机、可回滚。
（本提案不包含该收敛的实施 —— 改动 kube-system / monitoring 等
第三方 chart 的 RBAC 需逐个评估是否破坏其功能，属独立工作项。）

---

## 4. 迁移的真实成本（方案 A）

这一节是决策关键 —— seal 迁移**不是改个配置重启**那么简单。

```hcl
seal "ocikms" {
  crypto_endpoint    = "https://<vault-id>-crypto.kms.<region>.oraclecloud.com"
  management_endpoint = "https://<vault-id>-management.kms.<region>.oraclecloud.com"
  key_id             = "ocid1.key.oc1..."
}
```

**步骤与风险**：

1. 在 OCI 建 KMS vault + master key（**不可删除，只能 schedule deletion，
   最短 7 天**——建错了要等）
2. 配置 Vault 认证 —— 用 **instance principal**（节点在 OCI，无需 API key）
3. 加 `seal "ocikms"` **并保留原 shamir 配置**，重启后执行
   `vault operator unseal -migrate`（用现有 3 把 key 走一次迁移解封）
4. 确认迁移成功后才能移除 shamir 块
5. ★**迁移期间与之后，原 3 把 key 仍是恢复密钥（recovery keys）**——
   它们不再用于日常解封，但仍能用于 `vault operator generate-root` 等操作。
   **不能因为迁移完成就当它们无害**，仍需妥善保管（但可以移出集群）。

**必须人工执行的理由**：涉及 Vault 不可逆操作、需要持有 unseal key 本体、
且失败时可能导致 Vault 无法解封（数据仍在但取不出）。
**不能由自动化代劳**，也不应在无停机窗口时进行。

**回滚**：迁移前做 raft snapshot；若 `-migrate` 失败，用快照恢复并退回 shamir。
★快照本身含密文但不含 key，可安全存放。

---

## 5. 建议

**推荐方案 A（OCI KMS）**，理由：

1. 它是唯一**彻底**消除「key 与密文同处一地」的选项
2. OCI 在本环境已实测可用，不是引入一个全新的外部依赖
3. 方案 B 在单集群下是自欺欺人

★但**方案 C 的空间并未用尽**（第一版此处写错了）：收敛 19 个可读 SA 中
那些与 vault 无关的，是一条独立于本提案、成本低得多的改进路径，
建议先做 —— 它与 KMS 迁移不冲突，且迁移后仍然值得（KMS 迁移后
该 Secret 会变成 recovery key，仍需保护）。

**但建议分两步走，不要一次做完**：

- **第一步（低风险，可先做）**：建 KMS vault + key，配 IAM 动态组与 policy，
  从集群内一个临时 Pod 验证 instance principal 能调用该 key。
  ★这一步**不碰 Vault**，失败也不影响现有解封链路。
- **第二步（需停机窗口 + 人工）**：按 §4 执行 seal 迁移。

★两步之间可以停留任意久 —— 第一步的产出（可用的 KMS key + 已验证的授权链路）
本身就把「迁移能不能做成」这个最大不确定性消掉了。

**若决定暂不迁移**：#488 应保持 OPEN 并明确记为「已知且已接受的取舍」，
而不是关闭 —— 取舍被记录和被遗忘是两回事。

---

## 6. 本提案未做的事

- 未在 OCI 建任何资源（建 KMS vault 会产生费用且最短 7 天才能删）
- ~~未验证节点是否在 OCI 上~~ → **已验证**：4 个节点均为 OCI compute 实例
- 未配置 IAM 动态组与 policy（属实施步骤）
- 未执行任何 seal 迁移
