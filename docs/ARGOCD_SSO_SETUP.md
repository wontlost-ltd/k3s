# ArgoCD SSO Setup with Authentik

This guide explains how to configure Single Sign-On (SSO) for ArgoCD using Authentik as the identity provider.

## Prerequisites

1. Authentik running at `https://auth.aster-lang.cloud`
2. ArgoCD accessible via multiple domains:
   - `https://argocd.aster-lang.cloud` (primary)
   - `https://argocd.aster-lang.dev`
   - `https://argocd.ezymeta.com`
3. Vault configured with External Secrets

## Step 1: Create Authentik Application

1. Log into Authentik Admin Interface
2. Navigate to **Applications > Providers**
3. Click **Create** and select **OAuth2/OpenID Provider**
4. Configure the provider:

   | Field | Value |
   |-------|-------|
   | Name | ArgoCD |
   | Authorization flow | default-provider-authorization-implicit-consent |
   | Client type | Confidential |
   | Client ID | `argocd` |
   | Client Secret | (auto-generated, save this) |
   | Redirect URIs | See below (multiple domains) |
   | Signing Key | authentik Self-signed Certificate |

   **Redirect URIs** (add all three):
   ```
   https://argocd.aster-lang.cloud/auth/callback
   https://argocd.aster-lang.dev/auth/callback
   https://argocd.ezymeta.com/auth/callback
   ```

5. Click **Finish**

## Step 2: Create Authentik Application

1. Navigate to **Applications > Applications**
2. Click **Create**
3. Configure:

   | Field | Value |
   |-------|-------|
   | Name | ArgoCD |
   | Slug | argocd |
   | Provider | ArgoCD (created above) |
   | Launch URL | `https://argocd.aster-lang.cloud` |

4. Click **Create**

## Step 3: Configure Groups

Create groups in Authentik for ArgoCD RBAC:

1. Navigate to **Directory > Groups**
2. Create group: `argocd-admins` (full admin access)
3. Create group: `argocd-readonly` (read-only access)
4. Add users to appropriate groups

## Step 4: Store Client Secret in Vault

```bash
# Store the OIDC client secret in Vault
vault kv put secret/infrastructure/argocd \
  oidc_client_secret="YOUR_CLIENT_SECRET_FROM_AUTHENTIK"
```

## Step 5: SSO Configuration via GitOps

The SSO configuration is managed via GitOps and included in `argocd/kustomization.yaml`:

```yaml
resources:
  - sso-config.yaml  # Enabled by default
```

The ExternalSecret in `argocd/sso-config.yaml` automatically pulls the OIDC client secret from Vault.

To apply changes, simply commit and push - ArgoCD will auto-sync:

```bash
git add argocd/sso-config.yaml
git commit -m "Update SSO configuration"
git push

# If immediate restart is needed:
kubectl rollout restart deployment argocd-server -n argocd
```

## Step 6: Verify SSO

1. Open `https://argocd.aster-lang.cloud`
2. Click **LOG IN VIA AUTHENTIK**
3. Authenticate with Authentik
4. Verify you're logged in with correct permissions

## Troubleshooting

### OIDC Login Failed

Check ArgoCD server logs:
```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=100
```

### Invalid Redirect URI

Ensure all redirect URIs are configured in Authentik:
```
https://argocd.aster-lang.cloud/auth/callback
https://argocd.aster-lang.dev/auth/callback
https://argocd.ezymeta.com/auth/callback
```

The redirect URI must match the domain used to access ArgoCD.

### Groups Not Mapped

1. Check that Authentik is sending groups in the OIDC token
2. Verify the `scopes` configuration includes `groups`
3. Check the `policy.csv` in `argocd-rbac-cm` ConfigMap

### Disable Local Admin (Optional)

After verifying SSO works, you can disable the local admin:
```yaml
# In argocd-cm ConfigMap
data:
  admin.enabled: "false"
```

## Vault SSO Setup

Vault 已接入 Authentik OIDC。**role 定义以 `scripts/setup-vault-oidc-roles.sh` 为准**
（本节此前的示例与线上实际配置不符，已删除——详见下方"历史坑"）。

登录（★必须显式指定 role）：

```bash
export VAULT_ADDR=https://vault.aster-lang.cloud
vault login -method=oidc -path=Authentik role=admin
```

UI：认证方式选 OIDC → **Role 框填 `admin`**。留空会走 `default_role=default` → 只读。

> UI 的 Role 是自由文本、**无法做成下拉框**：列 role 需要 token（未认证请求实测返回 403），
> 而登录页尚未认证；role 名本身也会泄露权限分层。可用预填 URL 代替：
> `https://vault.aster-lang.cloud/ui/vault/auth?with=Authentik%2F&role=admin`

### 权限模型

| Authentik 组 | Vault role | 策略 | 说明 |
|---|---|---|---|
| `vault-admins` | `admin` | `vault-admin` | 全权（secret/auth/sys/identity）|
| `vault-operator` | `operator` | `vault-operator` | 组当前 0 成员，role 未绑组 |
| （任何人）| `default` | `default` + `vault-reader` | 兜底只读 |

### 历史坑：OIDC 登录后没有写权限

本节原先记录 `policies="default"`，导致 OIDC 登录只拿到只读的兜底 role。
实际排查发现的四处偏差：

1. **mount 路径是 `Authentik/` 而非 `oidc/`** —— 原文所有 `auth/oidc/...` 路径和
   callback URL 都是错的；
2. `admin` / `operator` role **早已存在**且绑好策略，问题只是登录时没指定 role
   （`default_role=default`）；
3. `bound_claims` 必须用 **stdin 传 JSON**，写成 `key=value` 会被 shell 拍平成字符串，
   Vault 报 `expected a map, got 'string'`；
4. Authentik 侧原本**没给 vault provider 绑 `groups` scope**，
   `.well-known` 的 `scopes_supported` 里没有 `groups` —— 此时若贸然给 role 配
   `bound_claims`，token 里根本没有 groups claim，会**直接把自己锁在门外**。

★ 另注：`vault write auth/Authentik/config` 是**整体替换**，而 `oidc_client_secret`
**不回显**。想改 `default_role` 就得把 client secret 一起重写，漏字段会导致
**所有人 OIDC 登录中断**。非必要不要动这个 config。

Create a separate Authentik provider for Vault following similar steps.
