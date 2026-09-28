# #488 OCI KMS 迁移 —— 准备进度与待办

> 承接 `488-seal-hardening-proposal.md` 的第 2 层(已定选型:OCI KMS)。
> 本文记录**已由 CLI 完成的零风险准备**、**须人工执行的剩余步骤**,
> 以及第 1 层 RBAC 审计的**可直接运行脚本**。

## 一、已完成（零风险，不碰运行中的 Vault）

在 OCI `ap-melbourne-1`(home region,与 k3s 集群同区)tenancy root
compartment 建好了 KMS Virtual Vault：

| 项 | 值 |
|---|---|
| Vault 名 | `vault-autounseal` |
| 类型 | `DEFAULT`(共享型,**前 20 key 版本免费**) |
| 状态 | ACTIVE |
| Vault OCID | `ocid1.vault.oc1.ap-melbourne-1.f5vlukbcaaclq.abwwkljr6oyp5dytick2kh4zxm3du6fhq4xh4vidsyafqqavujktu4dbgpqa` |
| management endpoint | `https://f5vlukbcaaclq-management.kms.ap-melbourne-1.oraclecloud.com` |
| crypto endpoint | `https://f5vlukbcaaclq-crypto.kms.ap-melbourne-1.oraclecloud.com` |

**可完全回退**:不再需要时 `oci kms management vault schedule-deletion` 即可
(有 7–30 天冷却期,期间可取消)。免费,留着也不产生费用。

## 二、待人工执行（我这侧的工具无法完成 --endpoint 操作）

### 2.1 建 AES master key（须带 --endpoint，故须你在本地 CLI 跑）

> `kms management key create` 强制要求顶层 `--endpoint` 指向 vault 的
> management endpoint;当前 MCP OCI 工具把 `--endpoint` 当全局选项拒绝,
> 故这一步须你在装了 oci CLI 的机器上执行。

```bash
oci kms management key create \
  --compartment-id ocid1.tenancy.oc1..aaaaaaaarmxr4dda6atrhji7o5hswrqz7towcjctrnrtd3kuuldcyjbrcs7a \
  --display-name vault-unseal-key \
  --key-shape '{"algorithm":"AES","length":32}' \
  --endpoint https://f5vlukbcaaclq-management.kms.ap-melbourne-1.oraclecloud.com
```
记下返回的 **key OCID**(下面 seal stanza 要用)。
`length:32` = AES-256;protection-mode 默认 HSM(免费额度内)。

### 2.2 授权 Vault Pod 调 KMS（Dynamic Group + Policy）

让运行 Vault 的 OCI 实例能调这把 key。用 instance principal(不落 API key):

```bash
# a) Dynamic Group —— 匹配 Vault 所在实例(按你的实例 OCID 或 compartment)
oci iam dynamic-group create \
  --name vault-unseal-instances \
  --description "Vault nodes that call KMS for auto-unseal" \
  --matching-rule "Any {instance.compartment.id = 'ocid1.tenancy.oc1..aaaaaaaarmxr4dda6atrhji7o5hswrqz7towcjctrnrtd3kuuldcyjbrcs7a'}"
#   ⚠ 上面用 compartment 粒度会匹配该 compartment **所有**实例。
#     更收敛的做法:改成 instance.id = '<vault-node-instance-ocid>'。

# b) Policy —— 只授「use」该 vault 里的 key(最小权限,不给 manage)
oci iam policy create \
  --compartment-id ocid1.tenancy.oc1..aaaaaaaarmxr4dda6atrhji7o5hswrqz7towcjctrnrtd3kuuldcyjbrcs7a \
  --name vault-unseal-kms \
  --description "Allow Vault instances to use the auto-unseal KMS key" \
  --statements '["Allow dynamic-group vault-unseal-instances to use keys in tenancy where target.key.id = '"'"'<KEY_OCID_FROM_2.1>'"'"'","Allow dynamic-group vault-unseal-instances to use key-delegate in tenancy where target.key.id = '"'"'<KEY_OCID_FROM_2.1>'"'"'"]'
```

### 2.3 Vault seal stanza（GitOps 可写，但迁移前先不 apply）

```hcl
seal "ocikms" {
  crypto_endpoint     = "https://f5vlukbcaaclq-crypto.kms.ap-melbourne-1.oraclecloud.com"
  management_endpoint = "https://f5vlukbcaaclq-management.kms.ap-melbourne-1.oraclecloud.com"
  key_id              = "<KEY_OCID_FROM_2.1>"
  auth_type_api_key   = false   # 用 instance principal
}
```

### 2.4 迁移仪式（不可逆，须 3 把现有 shamir key 在场）

```bash
# Vault 加上 ocikms seal 后重启,首次解封做迁移:
vault operator unseal -migrate   # 依次输入 3 把 shamir key
# 迁移后 rekey 淘汰旧 shamir(可选但建议)
vault operator rekey -init ...
```

### 2.5 善后（迁移成功后）

- 删除 `apps/infrastructure/vault/auto-unseal.yaml` 的 CronJob
- 删除 `vault-unseal-keys` Secret
  → **这一步直接消解了第 1 层要收敛的那个过宽授权 Secret**,#488 两层一并收口。

## 三、第 1 层 RBAC 审计（只读脚本，你在能连集群处跑）

`auto-unseal.yaml` 注释里的 19-SA 清单是 2026-09-05 的,可能已变。
下面脚本重新穷举「当前哪些 SA 能读 unseal Secret」,输出确切清单——
纯 `auth can-i`,**只读、零副作用**：

```bash
#!/usr/bin/env bash
# 谁能读 vault-unseal-keys —— 全 namespace 全 SA 穷举(只读)
set -euo pipefail
SECRET_NS="${1:-vault}"          # unseal Secret 所在 ns
SECRET="${2:-vault-unseal-keys}"
echo "能读 secret/$SECRET (ns=$SECRET_NS) 的 ServiceAccount："
for ns in $(kubectl get ns -o name | sed 's#namespace/##'); do
  for sa in $(kubectl -n "$ns" get sa -o name | sed 's#serviceaccount/##'); do
    if kubectl auth can-i get "secret/$SECRET" \
         -n "$SECRET_NS" \
         --as="system:serviceaccount:${ns}:${sa}" 2>/dev/null | grep -q '^yes$'; then
      echo "  ${ns}:${sa}"
    fi
  done
done
```

预期:**收敛前**能读者含 prometheus / reloader / traefik 等与 vault 无关的 SA;
**收敛后**(做完 RBAC PR)应只剩 auto-unseal CronJob 的 SA(+ 必要系统控制器)。
用**同一条脚本**验证收敛前后,不换判据。

> 注:若迁移到 OCI KMS 并删掉 unseal Secret(2.5),第 1 层的 RBAC 收敛
> **自然消失**——没有 Secret 就没有「谁能读它」的问题。故若你决定尽快
> 走 KMS 迁移,第 1 层可不必单独做;若 KMS 迁移要排期较晚,则先做第 1 层
> RBAC 收敛作为过渡缓解。
