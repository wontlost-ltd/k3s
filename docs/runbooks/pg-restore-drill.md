# PostgreSQL 恢复演练

**首次执行**：2026-09-05
**结论**：✅ 恢复成功且数据完全一致 —— 但**三次失败后才成功**，
每一次失败都是一个真实缺陷

---

## 0. 为什么必须做这个

**备份没验证过恢复 = 不知道有没有备份。**

本次演练前的状态是：CNPG 每小时备份、全部 `completed`、
可恢复窗口回溯至 2026-08-06 —— 看起来无懈可击。

**但实测第一次恢复直接失败。** 而且失败原因与备份本身无关 ——
备份一直是好的，是**恢复姿势**从未被验证过。

---

## 1. 三次失败（按发现顺序）

### 1.1 `no target backup found` —— serverName 未指定

```
error: while restoring cluster: no target backup found
```

**根因**：CNPG 按 `destinationPath/<serverName>/base/...` 找备份，
而 `serverName` **默认取新集群自己的名字**。

实测 bucket 里的真实路径是：

```
shared-postgres/shared-postgres/base/20260806T100201/data.tar.gz
                └─ 这一层是 serverName（生产集群名）
```

新集群叫 `restore-drill`，于是去找 `shared-postgres/restore-drill/base/` —— 不存在。

**修法**：`externalClusters[].barmanObjectStore.serverName: shared-postgres`

### 1.2 `unknown field "spec.externalClusters[0].serverName"` —— 字段放错层

我第一次把 `serverName` 放在 `externalClusters` 顶层，被 API server
以 strict decoding error 拒掉。它属于 **`barmanObjectStore` 这一层**。

★教训：CNPG 的 CRD 结构靠猜会错，直接读 schema：

```bash
kubectl get crd clusters.postgresql.cnpg.io -o json | python3 -c "
import sys,json
d=json.load(sys.stdin)
for v in d['spec']['versions']:
    if v['name']=='v1':
        ec=v['schema']['openAPIV3Schema']['properties']['spec']['properties']['externalClusters']['items']['properties']
        print('externalClusters:', sorted(ec.keys()))
        print('barmanObjectStore:', sorted(ec['barmanObjectStore']['properties'].keys()))"
```

（`kubectl explain` 在这里不好用 —— 输出把字段名和描述文本混在一起，
grep 出来全是 `The`、`When` 这类词。）

### 1.3 ★★PG 主版本不匹配 —— 最严重的一条

```
The data directory was initialized by PostgreSQL version 16,
which is not compatible with this version 18.1
pg_ctl: control file appears to be corrupt
```

**根因**：不写 `imageName` 时 CNPG 用**自己的默认版本**（实测 18.1），
而生产是 **16.4**。PostgreSQL 无法启动更旧主版本的数据目录。

★**这一条的意义远超本次演练**：它意味着如果真的发生灾难、
有人照着"标准流程"建恢复集群而没显式钉版本，**恢复会失败** ——
而那正是最不能失败的时刻。

★**并且它会随时间恶化**：生产钉在 16.4 不动，而 CNPG 的默认版本
会持续前移，两者差距只会越拉越大。

**修法**：`spec.imageName: ghcr.io/cloudnative-pg/postgresql:16.4`
（必须与生产**完全一致**）

---

## 2. 成功后的验证（行数一致 ≠ 内容一致）

### 2.1 行数比对

| 库 | 表 | 生产 | 恢复 | |
|---|---|---|---|---|
| aster_api | audit_logs | 4117 | 4117 | ✓ |
| aster_cloud | "Execution" | 878 | 878 | ✓ |
| authentik | authentik_core_user | 7 | 7 | ✓ |

★**不要用 `pg_stat_user_tables.n_live_tup`** —— 新实例上统计信息是空的，
会全部显示 0，看起来像"数据全没了"。我第一次就被这个误导。
用 `count(*)`。

### 2.2 ★内容级校验（这一步不能省）

行数一致只能说明"数量对"，不能说明"内容对"。用主键的 md5 聚合：

```sql
SELECT md5(string_agg(id::text, ',' ORDER BY id::text)) FROM audit_logs;
```

实测两库结果逐字节相同：

```
aster_api.audit_logs    生产 bc1cde611b94691e…  恢复 bc1cde611b94691e…  ✓
aster_cloud."Execution" 生产 e2ea8b29c7646bd9…  恢复 e2ea8b29c7646bd9…  ✓
```

---

## 3. 怎么跑

清单见 `pg-restore-drill.yaml`（已含上述三处修正）。

```bash
kubectl apply -f docs/runbooks/pg-restore-drill.yaml

# 约 2 分钟到 healthy
kubectl -n data-services get cluster restore-drill -w

# 验证（务必做内容级校验，不只看行数）
kubectl -n data-services exec restore-drill-1 -- \
  psql -U postgres -d aster_api -tAc "SELECT count(*) FROM audit_logs;"

# 清理
kubectl -n data-services delete cluster restore-drill
kubectl -n data-services delete pvc -l cnpg.io/cluster=restore-drill
```

★**演练对生产零影响**：全程只读 S3 备份，不碰生产集群。
实测演练前后生产 `Cluster in healthy state`、`audit_logs` 4117 行不变。

★资源开销刻意压低（100m/256Mi）并钉在 `master-1`（CPU requests 最低）——
其余节点已 75-83%，不能按生产规格再要一份。

---

## 4. 建议

1. **纳入定期演练**（建议季度一次）。本次证明了「备份 completed」
   与「能恢复」是两回事。
2. **PG 升级时同步更新本清单的 `imageName`** —— 否则演练本身会失败，
   而那时你会以为是备份坏了。
3. ★**考虑给生产集群加 `imageCatalogRef` 或在文档中固化版本**，
   让"恢复时该用哪个版本"有单一可信来源，而不是靠人记得。

---

## 5. 本次未验证的

- **PITR（时间点恢复）** —— 只验证了恢复到最新备份点
- **Vault raft 快照的恢复** —— 与 PG 独立，仍未演练
- **恢复后的应用连通性** —— 只验证了数据层，未接应用实测
