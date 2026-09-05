# 提案：把有状态数据迁到 OCI Block Volume

**状态**：待决策（需停机窗口）
**关联**：k3s#488（Vault 备份，#542 已合）、规模化商用差距评估

---

## 1. 要解决的问题

### 1.1 ★存储超额认领（最实在的一条）

`master-2` 上三个 PV 声明容量合计 **35Gi**，而该节点根盘**总共只有 29.4G、
剩余 6.5G**：

```
master-2  PV 声明   PG 20Gi + Vault data 10Gi + Vault audit 5Gi = 35Gi
master-2  根盘现状  29.4G 总 / 22.9G 已用 / 6.5G 可用（78%）
          其中 local-path 实际只占 1.7G
```

`local-path` **不预留空间** —— 声明多少不影响实际占用。所以现在没事，
但这意味着：**PG 数据长到 ~7G 时节点根盘就会满**，而 PVC 上写的是 20Gi。
届时不是「PVC 满了」这种清晰错误，而是**节点级磁盘耗尽** ——
kubelet 开始驱逐 Pod，波及该节点上的**所有**服务。

★这是「声称的容量」与「真实的容量」不一致，属于会在最坏时机暴露的那类问题。

### 1.2 四节点根盘都已 78–85%

```
master-1  29.4G / 23.2G 已用 / 6.2G 可用  (79%)
master-2  29.4G / 22.9G 已用 / 6.5G 可用  (78%)
master-3  29.4G / 23.2G 已用 / 6.2G 可用  (79%)
worker-1  29.4G / 25.1G 已用 / 4.3G 可用  (85%)  ← 最紧
```

★**驱逐阈值实测是 5%（非默认 10%）**：`evictionHard: {nodefs.available: 5%}`。
故 worker-1 的 14.6% 可用**尚有余量**，四节点当前 `DiskPressure=False`。
不是火烧眉毛，但没有增长空间 —— 大头是 OS + 容器镜像，不会自己变小。

### 1.3 数据绑死单节点（本提案**不解决**，见 §4）

`local-path` 的 PV 带 nodeAffinity，Pod 无法漂移。节点挂了 = 该节点上的
服务不可用且数据取不出来。

---

## 2. 可用资源与硬约束

```
master-block  50GB  vpu=10  AD-1  AVAILABLE（未挂载）
agent-block   50GB  vpu=10  AD-1  AVAILABLE（未挂载）
```

四个节点全在 **AD-1**，与卷同 AD（跨 AD 挂不了）。

### ★硬约束：OCI Block Volume 是**单实例挂载**的

同一时刻只能挂在一台实例上（多挂载需 UHP 且有额外限制）。这决定了：

**这两块卷做不出高可用。** 挂给 master-2 的卷，master-2 挂了就跟着不可用。
它们能做的是**把数据从系统盘挪到独立卷**，收益在别处（见 §3）。

★这一点必须说清楚，否则容易误以为「上了块存储就有 HA 了」。

---

## 3. 收益（诚实版）

| 收益 | 说明 |
|---|---|
| **消除超额认领** | 50G 独立卷 vs 声明 35Gi —— 名实相符 |
| **数据与系统盘解耦** | 节点重装 / 镜像撑爆根盘，不影响数据卷 |
| **★OCI 原生卷快照** | 这是最大的收益：卷级备份不需要在集群里再造一套 |
| 根盘压力解除 | worker-1 从 85% 降下来 |

**不提供的**：高可用、跨节点漂移、自动 failover。那需要 3 副本 + 网络存储
（Longhorn / Ceph），是另一个量级的工程。

---

## 4. 方案：两块卷各挂一个节点

```
master-block (50G) → master-2   承载 PG + Vault（当前 35Gi 声明）
agent-block  (50G) → worker-1   承载 Tempo + ckeditor（当前 6Gi 声明）
```

**为什么这样分**：master-2 是数据最关键的节点（PG + Vault），
worker-1 是根盘最紧的节点（85%）。两块卷正好各治一处。

★**未选 master-1/master-3**：它们上面是 Prometheus/Grafana/Redis，
丢了可重建（监控数据非业务数据、Redis 是缓存）。优先级低于 PG/Vault。

### 4.1 存储类选择

k3s 自带 `local-path`（默认）。挂载块存储后有两条路：

**(a) 仍用 local-path，但把它的目录指到块存储挂载点**
- 改 `local-path-provisioner` 的 ConfigMap，把 `paths` 指向 `/mnt/data`
- 优点：改动最小，现有 PVC 语义不变
- 缺点：**仍然是 node-local**，nodeAffinity 依旧

**(b) 引入 OCI CSI 驱动，用 `oci-bv` StorageClass**
- 优点：PVC 直接对应 OCI 卷，支持卷快照 CRD、在线扩容
- 缺点：需装 CSI driver + 配 instance principal 权限；且**仍是单挂载**，
  Pod 依然不能跨节点漂移（卷会跟着 detach/attach，但有中断）

★**建议先做 (a)**：它解决 §1.1 和 §1.2 两个真实问题，改动可控。
(b) 的增量收益主要是「卷快照走 K8s API」，但 OCI 侧的自动备份策略
同样能做到，不必为此引入 CSI 的运维复杂度。

---

## 5. 迁移步骤（需停机窗口）

★**每一步都可回滚**，且数据在最后一刻才动。

### 阶段 0：准备（无停机）

```bash
# 1. 挂载卷到实例（OCI 侧，不影响运行中的 k3s）
oci compute volume-attachment attach --type paravirtualized \
  --instance-id <master-2 OCID> --volume-id <master-block OCID>

# 2. 节点上格式化并挂载（需 SSH 到节点）
sudo mkfs.xfs /dev/oracleoci/oraclevdb
sudo mkdir -p /mnt/data
sudo blkid /dev/oracleoci/oraclevdb          # 取 UUID
echo 'UUID=<uuid> /mnt/data xfs defaults,_netdev,nofail 0 2' | sudo tee -a /etc/fstab
sudo mount -a && df -h /mnt/data
```

★`_netdev,nofail` 两个选项都必要：前者让系统知道要等网络块设备就绪，
后者保证**卷不可用时节点仍能启动** —— 否则一次卷故障会让节点起不来，
把「一个服务不可用」放大成「整台机器不可用」。

### 阶段 1：备份（停机前必做）

```bash
# PG：CNPG 已有每小时备份，确认最近一次成功
kubectl -n data-services get backup --sort-by=.metadata.creationTimestamp | tail -1

# Vault：用 #542 的快照任务手动跑一次
kubectl -n vault create job vault-snap-premigrate --from=cronjob/vault-raft-snapshot
kubectl -n vault logs job/vault-snap-premigrate -c upload
```

★**这一步不能省**。后面要动的是这两个服务的数据目录。

### 阶段 2：迁移（停机）

```bash
# 1. 缩容有状态服务
kubectl -n data-services patch cluster shared-postgres --type merge -p '{"spec":{"instances":0}}'
kubectl -n vault scale statefulset vault --replicas=0

# 2. 复制数据（保留权限/属主，这对 PG 是硬要求）
sudo cp -a /var/lib/rancher/k3s/storage/. /mnt/data/

# 3. 改 local-path 的路径配置
kubectl -n kube-system edit configmap local-path-config
#   config.json 里 "paths": ["/var/lib/rancher/k3s/storage"] → ["/mnt/data"]
kubectl -n kube-system rollout restart deploy/local-path-provisioner

# 4. 恢复
kubectl -n vault scale statefulset vault --replicas=1
kubectl -n data-services patch cluster shared-postgres --type merge -p '{"spec":{"instances":1}}'
```

★`cp -a` 而非 `cp -r`：PG 对数据目录的属主与权限极其敏感，
属主错了会直接拒绝启动（而且报错信息不明显）。

### 阶段 3：验证

```bash
kubectl -n vault exec vault-0 -- vault status          # 应 Sealed=false（auto-unseal 会处理）
kubectl -n data-services get cluster shared-postgres   # 应 healthy
df -h /mnt/data                                        # 数据确实在新卷上
kubectl get pvc -A                                     # 全部 Bound
```

### 回滚

阶段 2 的第 3 步改回原路径 + 重启 provisioner 即可 ——
**原数据一直留在 `/var/lib/rancher/k3s/storage`，全程未删**。
确认新卷稳定运行一段时间后再清理旧目录。

---

## 6. 后续（不在本提案范围）

1. **配 OCI 卷自动备份策略** —— 这是挂卷的最大收益，挂完就该配
2. **PG instances=2** —— 用户已问及；资源上可行（PG 现占 588Mi），
   但备库仍在 local-path，达成的是「两节点各一份」而非真正的存储 HA
3. **★Vault 不要 replicas=2** —— Raft 需奇数节点：2 副本的 quorum 是 2，
   **挂任一台整个 Vault 就不可用**，比单副本更差。要 HA 就直接 3 副本

---

## 7. 本提案未做的事

- 未挂载任何卷、未格式化、未改任何 StorageClass
- 未验证节点上 `/dev/oracleoci/oraclevdb` 的实际设备名（需挂载后确认）
- 未做 OCI CSI 驱动的可行性验证（方案 b，暂不推荐）
