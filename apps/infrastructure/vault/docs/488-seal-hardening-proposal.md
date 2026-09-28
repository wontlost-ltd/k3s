# Vault seal 加固方案（k3s#488）

> **状态:方案文档,不改运行配置。** 本文只提出、论证、排序修复项;
> 实际执行(尤其 KMS 迁移、rekey)涉及不可逆的 Vault 密钥仪式,
> 必须人工进行,不由自动化代劳。

## 一、问题（来自 #488 与 `auto-unseal.yaml` 实测）

3 把 unseal key 以普通 K8s Secret(`vault-unseal-keys`,ns `vault`)存于
**同一集群**,CronJob 每 5 分钟自动解封。后果:

> **seal 保护对「已取得集群内相应读权限的攻击者」实质失效。**

seal 的设计目的是「即使拿到存储也读不到数据」。key 与密文同处一地时,
拿到 etcd 快照 / 节点磁盘的人也就拿到了 key。

### 已实测的暴露面（2026-09-05 全集群 SA 穷举，见 auto-unseal.yaml 注释）

- **19 个 ServiceAccount 能读该 Secret**。
- 其中 `prometheus-grafana` / `reloader` / `traefik` / `policy-controller`
  等**与 vault 毫无职能关系** —— 纯过宽授权。
- vault 自己的 SA **不能**读(kubelet 注入 env 不需要 SA 有 secrets 权限)。
- key 从未进 git(工作区与全历史 0 命中)。

## 二、修复分两层：先做低成本高收益的，KMS 迁移作为中期目标

### 第 1 层:RBAC 收敛（低成本、可 GitOps、无需密钥仪式）★优先

那 19 个 SA 里,与 vault 无关的能读 unseal key,是第三方 chart 默认授予的
**集群级 `secrets get/list`** 顺带覆盖到本 Secret。收敛思路(按侵入性从低到高):

1. **给 unseal Secret 加一道显式的读取白名单(推荐首选)**
   - K8s 原生没有「Secret 级 deny」,但可用**专用 namespace + NetworkPolicy 无关**
     的思路行不通;真正有效的是**收敛那些 ClusterRole 的 `secrets` 动词范围**。
   - 对可控的第三方 chart(reloader / reflector 等本仓自管的),把其 ClusterRole
     的 `secrets` 权限从集群级收敛为**按 namespace 的 Role**,或加
     `resourceNames` 限定到它们真正需要的 Secret,排除 `vault-unseal-keys`。
   - **可 GitOps**:改动落在各 chart 的 values / RBAC override,走正常 PR。

2. **把 unseal Secret 隔离到独立 namespace + 最小 RBAC**
   - 现在它在 `vault` ns。迁到一个**只有 auto-unseal CronJob 的 SA 能读**的
     专用 ns(如 `vault-unseal`),该 ns 不授予任何集群级 secrets 读的 chart。
   - CronJob 的 SA 用 `resourceNames: [vault-unseal-keys]` 的 Role,最小权限。
   - 代价:改 CronJob 的 secretKeyRef 来源 ns,需一次人工重建 Secret。

3. **审计并移除无关 SA 的集群级 secrets 权限**
   - `prometheus` / `grafana` / `traefik` 等能读**全集群 secrets** 本身就是
     过宽(它们只需各自 ns 内的少数 Secret)。逐个核其 chart 是否支持
     `rbac.create` + 限定范围,收敛掉集群级 `secrets`。
   - 这条收益最广(不止保护 unseal key),但要逐 chart 验证不破坏功能。

> **判据**:收敛后重跑 `auto-unseal.yaml` 注释里那条全 SA 穷举
> (`for each ns/sa: kubectl auth can-i get secret/vault-unseal-keys`),
> 能读的 SA 应只剩 auto-unseal CronJob 的 SA(+ 必要的系统控制器)。
> **不改判据、用同一条命令验证收敛前后**。

### 第 2 层:KMS / transit auto-unseal（中期，需人工密钥仪式）

根治「key 与密文同集群」的唯一办法是把 unseal 委托给**集群外**的密钥:

- **选项 A — cloud KMS**(`awskms` / `gcpckms` / `azurekeyvault`):
  seal stanza 指向云 KMS,key 不再落地集群。本集群在 OCI,可评估
  **OCI KMS**(Vault 的 `ocikms` seal)或经 transit 桥接。
- **选项 B — transit auto-unseal**:另起一个**独立信任域**的 Vault(或
  同集群外的实例)作 transit,主 Vault 用它解封。仍需那个 transit 实例
  自身的 seal 管理,只是把问题移到边界更清晰的地方。

**为何必须人工:**
- 迁移 seal 类型是 `vault operator unseal -migrate` 流程,**不可逆**,
  且中途需现有 3 把 key 在场。
- 迁移后应 **rekey** 淘汰旧 key。
- 这两步是密钥仪式,不能由 CI/自动化持有或代劳。

## 三、已完成、无需再做的部分（避免重复投入）

`auto-unseal.yaml` 已闭环的项(实测记录在其注释):

- ✅ **文档化取舍** —— 文件头大段说明,即 #488 建议的「显式承认」。
- ✅ **不再 `VAULT_SKIP_VERIFY`** —— 改挂 `ca.crt` 验证内部 CA(有效期到 2035)。
- ✅ **防 `last-applied` 注解泄露** —— 明确要求 `create` 而非 `apply`,
  避免 key 以明文进注解(曾发生并已清理)。
- ✅ **无 git 泄露 / 无备份 CR 覆盖 / 无残留明文副本** —— 全扫确认。

## 四、建议的推进顺序

1. **先做第 1 层第 3 项的审计**(全 SA 穷举,量化当前过宽授权),产出
   「哪些 SA 该收敛」的确切清单 —— 这一步只读、零风险,可立即做。
2. **按清单做 RBAC 收敛 PR**(第 1 层第 1/2 项),每改一个 chart 用同一条
   穷举命令验证「能读者减少且功能不破」。
3. **KMS 迁移作为独立的、计划内的运维窗口**执行,需密钥保管人在场。

## 五、留给决策者的问题

- 第 1 层是否现在就推进?(纯 RBAC,可 GitOps,我可以先做只读审计出清单)
- 第 2 层选 OCI KMS 还是 transit?这决定选型与迁移窗口。
