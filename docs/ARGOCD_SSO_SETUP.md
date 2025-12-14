# ArgoCD SSO Setup with Authentik

This guide explains how to configure Single Sign-On (SSO) for ArgoCD using Authentik as the identity provider.

## Prerequisites

1. Authentik running at `https://auth.aster-lang.cloud`
2. ArgoCD running at `https://argocd.aster-lang.cloud`
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
   | Redirect URIs | `https://argocd.aster-lang.cloud/auth/callback` |
   | Signing Key | authentik Self-signed Certificate |

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

Ensure the redirect URI in Authentik matches exactly:
```
https://argocd.aster-lang.cloud/auth/callback
```

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

Vault can also use OIDC with Authentik:

```bash
# Enable OIDC auth method
vault auth enable oidc

# Configure OIDC
vault write auth/oidc/config \
    oidc_discovery_url="https://auth.aster-lang.cloud/application/o/vault/" \
    oidc_client_id="vault" \
    oidc_client_secret="YOUR_VAULT_CLIENT_SECRET" \
    default_role="default"

# Create default role
vault write auth/oidc/role/default \
    bound_audiences="vault" \
    allowed_redirect_uris="https://vault.aster-lang.cloud/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="http://localhost:8250/oidc/callback" \
    user_claim="sub" \
    policies="default"
```

Create a separate Authentik provider for Vault following similar steps.
