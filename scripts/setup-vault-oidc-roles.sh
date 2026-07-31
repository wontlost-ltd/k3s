#!/usr/bin/env bash
#
# Vault OIDC（Authentik）role 定义 —— 可复现脚本
#
# 为什么有这个脚本：Vault 的 auth method / policy / role **全部是手工 `vault write` 的**，
# 不在 GitOps 里。集群重建或配置被改后无从对照，且文档会悄悄过时——
# `docs/ARGOCD_SSO_SETUP.md` 里长期写着 `policies="default"`，而那正是
# 「OIDC 登录后没有写权限」的病根（见本文件末尾的排查记录）。
# 这里把**实际生效的配置**固化成脚本，改配置请改这里再执行。
#
# 前置：
#   1) Authentik 侧 vault provider 必须绑定 `groups` scope mapping
#      （本环境是自建的 "ArgoCD Groups Mapping"，scope_name=groups，
#        expression 为 `[group.name for group in request.user.ak_groups.all()]`；
#        名字带 ArgoCD 只是历史命名，通用可复用）
#      验证：curl -s https://auth.aster-lang.cloud/application/o/vault/.well-known/openid-configuration \
#              | jq .scopes_supported     # 必须含 "groups"
#   2) 对应 Authentik 组必须**有成员**（vault-admins / vault-operator / vault-defaults）
#   3) 需要 root 或具备 auth/* 写权限的 token
#
# 用法（在能连到 Vault 的机器上）：
#   export VAULT_ADDR=https://vault.aster-lang.cloud
#   vault login -method=oidc -path=Authentik role=admin
#   ./scripts/setup-vault-oidc-roles.sh
#
# 或在集群内：
#   kubectl exec -i -n vault vault-0 -- env VAULT_SKIP_VERIFY=true sh < scripts/setup-vault-oidc-roles.sh

set -euo pipefail

MOUNT="${VAULT_OIDC_MOUNT:-Authentik}"
UI_CALLBACK="https://vault.aster-lang.cloud/ui/vault/auth/${MOUNT}/oidc/callback"
CLI_CALLBACK="http://localhost:8250/oidc/callback"

# ★ 用 stdin 传 JSON，不要用 `key=value` 形式。
#   `bound_claims` 是 map，走命令行会被 shell 拍平成字符串，Vault 报
#   `expected a map, got 'string'`。
write_role() {
    local role="$1" group="$2" policy="$3"
    vault write "auth/${MOUNT}/role/${role}" - <<JSON
{
  "bound_audiences": ["vault"],
  "allowed_redirect_uris": ["${UI_CALLBACK}", "${CLI_CALLBACK}"],
  "user_claim": "sub",
  "oidc_scopes": ["groups"],
  "groups_claim": "groups",
  "bound_claims": {"groups": ["${group}"]},
  "policies": ["${policy}"]
}
JSON
    echo "  ✓ role ${role}: 组 ${group} → 策略 ${policy}"
}

echo "配置 Vault OIDC roles（mount=${MOUNT}）"
write_role admin    vault-admins   vault-admin

# ★ operator 暂不绑组：`vault-operator` 组当前**0 成员**（vault-defaults 同样为空）。
#   现在绑上去，等于把这个 role 变成谁也登不进的死配置。
#   等真的往组里加人时，再取消下面这行的注释并执行本脚本。
# write_role operator vault-operator vault-operator

# ★ default role 不绑 bound_claims：它是 `default_role`，即**未指定 role 时的兜底**。
#   绑了组之后，不在该组的人会直接登录失败而非降级只读，体验和排障都更差。
#   故保持"任何能通过 Authentik 的人都能登，但只有只读"。
vault write "auth/${MOUNT}/role/default" - <<JSON
{
  "bound_audiences": ["vault"],
  "allowed_redirect_uris": ["${UI_CALLBACK}", "${CLI_CALLBACK}"],
  "user_claim": "sub",
  "policies": ["default", "vault-reader"]
}
JSON
echo "  ✓ role default: 无组限制 → 只读（default + vault-reader）"

cat <<'NOTE'

登录方式（★必须显式指定 role）：
  vault login -method=oidc -path=Authentik role=admin
  UI: 认证方式选 OIDC → Role 框填 admin

  留空会走 default_role=default → 只拿到 vault-reader 只读。

  UI 的 Role 是自由文本、无法做成下拉框：列 role 需要 token（未认证请求返回 403），
  而登录页尚未认证；role 名本身也会泄露权限分层。可用预填 URL 代替：
    https://vault.aster-lang.cloud/ui/vault/auth?with=Authentik%2F&role=admin

验证：
  vault token lookup | grep policies    # 期望 ["vault-admin"]
NOTE
