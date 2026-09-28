# #488 迁移前必修:两处 IAM 配置缺陷（须人工执行）

> 迁移前用 OCI CLI 只读核实 2.1/2.2 的产物,发现两处会导致
> `unseal -migrate` 失败的配置缺陷。二者都有确定的正确值,但属**权限
> 配置改动**,须你人工执行。修完再做迁移仪式。

## 核实结果（2026-09-28，只读）

| 项 | 现状 | 问题 |
|---|---|---|
| KMS key | OCID `ocid1.key.oc1.ap-melbourne-1.f5vlukbcaaclq.abwwkljrpdxjzlyideb675qx3nfs5h34sss4tcsejpw4uudt7koezd4qwgeq`(从 policy 第 2 条读出) | ✅ 已建 |
| dynamic-group `vault-unseal-instances` | 存在,但 **`matching-rule` = null** | ❌ 匹配规则空 → 不匹配任何实例 → 权限授给空集 |
| policy `vault-unseal-kms` 第 1 条 | `target.key.id = '<KEY_OCID_FROM_2.1>'` | ❌ 占位符未替换 → 缺 `use keys` 权限 |
| policy 第 2 条 | key OCID 已填真值 | ✅ 对 |

**根因**:执行 §2.2 命令时占位符 `<KEY_OCID_FROM_2.1>` 未替换,且
dynamic-group 的 `--matching-rule` 未成功设上(可能被 shell 引号吞掉)。

## 修复 1:补上 dynamic-group 的匹配规则

匹配该 compartment 下**所有实例**(Vault pod 可能被调度到任一 k3s 节点,
只匹配单实例会在 pod 漂移后失权、Vault 起不来解不了封):

```bash
oci iam dynamic-group update \
  --dynamic-group-id ocid1.dynamicgroup.oc1..aaaaaaaadukdxjyu5efm5djgtehojhmsbpwbbpupxalmg5lzvka57zdtnqoq \
  --matching-rule "Any {instance.compartment.id = 'ocid1.tenancy.oc1..aaaaaaaarmxr4dda6atrhji7o5hswrqz7towcjctrnrtd3kuuldcyjbrcs7a'}" \
  --force
```

核实:

```bash
oci iam dynamic-group get \
  --dynamic-group-id ocid1.dynamicgroup.oc1..aaaaaaaadukdxjyu5efm5djgtehojhmsbpwbbpupxalmg5lzvka57zdtnqoq \
  --query 'data."matching-rule"'
# 应输出上面那条规则,不再是 null
```

## 修复 2:替换 policy 第 1 条的占位符

用真实 key OCID 重写 policy 的两条语句(第 2 条本就对,一并写全保持一致):

```bash
oci iam policy update \
  --policy-id "$(oci iam policy list \
      --compartment-id ocid1.tenancy.oc1..aaaaaaaarmxr4dda6atrhji7o5hswrqz7towcjctrnrtd3kuuldcyjbrcs7a \
      --all --query "data[?name=='vault-unseal-kms'].id | [0]" --raw-output)" \
  --statements '[
    "Allow dynamic-group vault-unseal-instances to use keys in tenancy where target.key.id = '"'"'ocid1.key.oc1.ap-melbourne-1.f5vlukbcaaclq.abwwkljrpdxjzlyideb675qx3nfs5h34sss4tcsejpw4uudt7koezd4qwgeq'"'"'",
    "Allow dynamic-group vault-unseal-instances to use key-delegate in tenancy where target.key.id = '"'"'ocid1.key.oc1.ap-melbourne-1.f5vlukbcaaclq.abwwkljrpdxjzlyideb675qx3nfs5h34sss4tcsejpw4uudt7koezd4qwgeq'"'"'"
  ]' \
  --force
```

核实:

```bash
oci iam policy list \
  --compartment-id ocid1.tenancy.oc1..aaaaaaaarmxr4dda6atrhji7o5hswrqz7towcjctrnrtd3kuuldcyjbrcs7a \
  --all --query "data[?name=='vault-unseal-kms'].statements" --output json
# 两条都应含真实 key OCID,不再有 <KEY_OCID_FROM_2.1>
```

## 修完之后

两处修好、核实通过后,才进入 `488-oci-kms-setup.md` §2.3 起的:
seal stanza → `unseal -migrate`(须 3 把 shamir key 在场)→ rekey → 善后删
auto-unseal CronJob + unseal Secret。

> IAM 变更需 ~1 分钟传播;修完稍等再做迁移,避免 Vault 首次调 KMS 时
> 权限尚未生效而报 401/403。
