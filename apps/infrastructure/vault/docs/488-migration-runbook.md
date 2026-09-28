# #488 KMS 迁移操作手册（runbook）

> 前置已就绪并核实:KMS key 已建、policy 两条语句填真实 OCID、
> dynamic-group matching-rule 匹配 compartment 所有实例。
> 本手册是**人工执行**的迁移仪式,含**回退路径**——OCI KMS auto-unseal
> 的关键安全网:即使权限没通,旧的 3 把 shamir key 仍能手动解封回退,
> **不会一迁就锁死**。

## 关于「迁移前连通性测试」

理想是先用 instance principal 试调一次 KMS encrypt 证明授权链通。但:
- master-2 无 oci CLI;临时 pod(ghcr oci-cli 镜像)在本环境拉取超时。
- **不必强求**:三个授权环节已只读核实齐全;且迁移本身可回退。

若仍想先测,可在 master-2 用节点已有的 containerd 拉一个能装 oci CLI 的镜像,
或直接进迁移——权限没通时按下方「回退」退回,代价只是多重启一次。

## 迁移步骤

### 1. 加 seal stanza 到 Vault config（GitOps）

`application.yaml` 的 `ha.raft.config` HCL 里,与 `storage "raft"` 同级加:

```hcl
seal "ocikms" {
  crypto_endpoint     = "https://f5vlukbcaaclq-crypto.kms.ap-melbourne-1.oraclecloud.com"
  management_endpoint = "https://f5vlukbcaaclq-management.kms.ap-melbourne-1.oraclecloud.com"
  key_id              = "ocid1.key.oc1.ap-melbourne-1.f5vlukbcaaclq.abwwkljrpdxjzlyideb675qx3nfs5h34sss4tcsejpw4uudt7koezd4qwgeq"
  auth_type_api_key   = "false"   # 用 instance principal(master-2 的身份)
}
```

⚠️ `auth_type_api_key` 值是**字符串** `"false"`(HCL 里 ocikms seal 的写法)。

提交后 ArgoCD 同步,但 **pod 不会自动重启加载新 seal**——需手动 rollout(下一步)。

### 2. 迁移仪式（人工，不可逆）

> **3 把 shamir key 从哪来?** 就在集群里 —— `vault operator init` 当初用
> 默认 5 shares / 门槛 3,这 3 把存在 `vault -n vault secret/vault-unseal-keys`
> 的 `UNSEAL_KEY_1/2/3`(auto-unseal CronJob 一直用它们解封)。故**不需要
> 你另外保管**,迁移时从 Secret 读出即可。
>
> ⚠️ 迁移完成前**不要删**这个 Secret —— 它既是迁移用的 key,也是回退凭据。

```bash
# a) 先把 3 把 shamir key 读进本地变量(从集群 Secret,base64 解码)
K1=$(kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.UNSEAL_KEY_1}' | base64 -d)
K2=$(kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.UNSEAL_KEY_2}' | base64 -d)
K3=$(kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.UNSEAL_KEY_3}' | base64 -d)

# b) 重启 vault-0 加载含 ocikms seal 的新 config
kubectl -n vault rollout restart statefulset vault
kubectl -n vault rollout status statefulset vault --timeout=120s

# c) vault-0 重启后处于 sealed 且等待迁移。用这 3 把 key 逐个 -migrate:
#    -migrate 告诉 Vault:从 shamir 迁到 config 里的新 seal(ocikms)。
#    达到门槛 3 后,Vault 用 ocikms 完成解封并记录迁移。
kubectl -n vault exec -i vault-0 -- vault operator unseal -migrate "$K1"
kubectl -n vault exec -i vault-0 -- vault operator unseal -migrate "$K2"
kubectl -n vault exec -i vault-0 -- vault operator unseal -migrate "$K3"

# d) 确认已解封且 seal 类型变为 kms:
kubectl -n vault exec vault-0 -- vault status
#    期望:Sealed=false;Seal Type 显示 ocikms(旧 Recovery Seal Type=shamir)
```

> ⚠️ 用完 unset 掉本地变量,别留在 shell 历史:`unset K1 K2 K3`

### 3. 验证 KMS auto-unseal 真的生效

```bash
# 删掉 pod 让它重启,这次应**自动**用 KMS 解封,无需人工、无需 CronJob:
kubectl -n vault delete pod vault-0
kubectl -n vault rollout status statefulset vault --timeout=120s
kubectl -n vault exec vault-0 -- vault status   # Sealed 应直接 false
```
若这一步 pod 自动解封 → KMS auto-unseal 成功,权限链全通。

### 4. 善后（迁移确认成功后）

```bash
# a) rekey 淘汰旧 shamir(可选但建议——旧 key 已不用于解封,但仍是恢复凭据)
kubectl -n vault exec -it vault-0 -- vault operator rekey -init -key-shares=3 -key-threshold=3
#    按提示完成,妥善保管新 recovery key。

# b) 删除不再需要的 auto-unseal CronJob 与 unseal Secret(GitOps + 手动)
#    - 从 kustomization/config-application 移除 auto-unseal.yaml
#    - kubectl -n vault delete secret vault-unseal-keys
#    → 这一步直接消解 #488 第 1 层要收敛的那个过宽授权 Secret,两层一并收口。
```

## 回退路径（若第 2 步权限没通、迁移失败）

OCI KMS seal 迁移**不会锁死数据**——回退方式:

1. **撤下 seal stanza**:从 config 移除 `seal "ocikms"` 块,rollout restart。
2. Vault 回到纯 shamir seal,用 3 把 shamir key 手动 `vault operator unseal`
   (不带 -migrate)即可解封。
3. 排查权限(常见:IAM 未传播,等几分钟;或 master-2 不在 dynamic-group,
   确认 pod 仍在 master-2)。
4. 修好后重来第 1-2 步。

> 关键:**迁移前不要删 shamir key、不要删 auto-unseal Secret** —— 它们是
> 回退凭据。只有第 3 步验证 KMS 自动解封成功后,才做第 4 步善后。

## 迁移中若卡住的诊断

- `unseal -migrate` 报 KMS 401/403 → instance principal 授权链没通:
  确认 dynamic-group 匹配 master-2、policy 两条 use keys/key-delegate 都在、
  IAM 已传播(等 1-2 分钟)。
- pod CrashLoop / 起不来 → 看 `kubectl -n vault logs vault-0`,
  多为 seal stanza 语法(auth_type_api_key 须字符串 "false")或 endpoint 拼错。
