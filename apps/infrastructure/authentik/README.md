# Authentik Setup

Authentik is an open-source Identity Provider (IdP) that provides SSO, user management, and authentication.

## Prerequisites

1. PostgreSQL database available
2. DNS record for `auth.aster-lang.cloud` pointing to cluster
3. SMTP server for email notifications (optional but recommended)

## Pre-Installation: Create Secrets

### 1. Create Authentik Namespace

```bash
kubectl create namespace authentik
```

### 2. Generate Secret Key

```bash
# Generate a secure secret key
AUTHENTIK_SECRET_KEY=$(openssl rand -base64 36)
echo "Secret Key: $AUTHENTIK_SECRET_KEY"
```

### 3. Create PostgreSQL Database

If using external PostgreSQL:

```bash
# Connect to PostgreSQL and create database
psql -h <postgres-host> -U postgres

CREATE DATABASE authentik;
CREATE USER authentik WITH ENCRYPTED PASSWORD 'your-secure-password';
GRANT ALL PRIVILEGES ON DATABASE authentik TO authentik;
\q
```

### 4. Create Kubernetes Secrets

```bash
# Create secret with all required values
kubectl create secret generic authentik-secrets -n authentik \
  --from-literal=AUTHENTIK_SECRET_KEY="$AUTHENTIK_SECRET_KEY" \
  --from-literal=AUTHENTIK_POSTGRESQL__HOST="postgres.wontlost-data.svc.cluster.local" \
  --from-literal=AUTHENTIK_POSTGRESQL__PORT="5432" \
  --from-literal=AUTHENTIK_POSTGRESQL__NAME="authentik" \
  --from-literal=AUTHENTIK_POSTGRESQL__USER="authentik" \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="your-secure-password" \
  --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="admin-initial-password" \
  --from-literal=AUTHENTIK_BOOTSTRAP_EMAIL="admin@aster-lang.cloud"
```

### 5. Update Application to Use Secrets

Update `application.yaml` to include:

```yaml
# In the helm values section, add:
envFrom:
  - secretRef:
      name: authentik-secrets
```

## Post-Installation

### 1. Access Authentik

```bash
# Get the initial admin password (if set via bootstrap)
# Or check the logs for the initial setup token

# Access UI
open https://auth.aster-lang.cloud
```

### 2. Initial Admin Login

- URL: `https://auth.aster-lang.cloud/if/flow/initial-setup/`
- Or use the bootstrap credentials if configured

### 3. Configure Authentik

#### Create OAuth2/OIDC Provider for Applications

1. Go to **Admin Interface** → **Applications** → **Providers**
2. Click **Create** → **OAuth2/OpenID Provider**
3. Configure:
   - Name: `policy-api`
   - Authorization flow: `default-authorization-flow`
   - Client ID: (auto-generated or custom)
   - Client Secret: (auto-generated)
   - Redirect URIs: `https://api.aster-lang.cloud/callback`

#### Create Application

1. Go to **Applications** → **Applications**
2. Click **Create**
3. Configure:
   - Name: `Policy API`
   - Slug: `policy-api`
   - Provider: Select the OAuth2 provider created above

## Integrating Applications with Authentik

### OAuth2/OIDC Integration

Use these endpoints in your application:

```
Authorization URL: https://auth.aster-lang.cloud/application/o/authorize/
Token URL: https://auth.aster-lang.cloud/application/o/token/
User Info URL: https://auth.aster-lang.cloud/application/o/userinfo/
JWKS URL: https://auth.aster-lang.cloud/application/o/<app-slug>/jwks/
```

### Example: Protect Traefik Ingress with Authentik

1. Create **Proxy Provider** in Authentik for forward auth
2. Add Traefik middleware:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-auth
  namespace: aster-policy
spec:
  forwardAuth:
    address: http://authentik-server.authentik.svc.cluster.local/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
      - X-authentik-uid
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: policy-api
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: aster-policy-authentik-auth@kubernetescrd
spec:
  # ... rest of ingress config
```

### Example: Quarkus OIDC Integration

```properties
# application.properties
quarkus.oidc.auth-server-url=https://auth.aster-lang.cloud/application/o/policy-api/
quarkus.oidc.client-id=<client-id>
quarkus.oidc.credentials.secret=<client-secret>
quarkus.oidc.application-type=service
```

### Example: Spring Boot OIDC Integration

```yaml
# application.yml
spring:
  security:
    oauth2:
      client:
        registration:
          authentik:
            client-id: <client-id>
            client-secret: <client-secret>
            scope: openid,profile,email
            authorization-grant-type: authorization_code
            redirect-uri: "{baseUrl}/login/oauth2/code/{registrationId}"
        provider:
          authentik:
            issuer-uri: https://auth.aster-lang.cloud/application/o/policy-api/
```

## Vault Integration with Authentik

You can use Authentik as the OIDC provider for Vault:

```bash
# Enable OIDC auth method in Vault
vault auth enable oidc

# Configure OIDC
vault write auth/oidc/config \
    oidc_discovery_url="https://auth.aster-lang.cloud/application/o/vault/" \
    oidc_client_id="<vault-client-id>" \
    oidc_client_secret="<vault-client-secret>" \
    default_role="reader"

# Create role
vault write auth/oidc/role/reader \
    bound_audiences="<vault-client-id>" \
    allowed_redirect_uris="https://vault.aster-lang.cloud/ui/vault/auth/oidc/oidc/callback" \
    user_claim="sub" \
    policies="reader"
```

## LDAP Integration (for legacy apps)

Authentik can also provide LDAP:

1. Create **LDAP Provider** in Authentik
2. Create **LDAP Outpost**
3. Configure legacy apps to use:
   - LDAP URL: `ldap://authentik-ldap.authentik.svc.cluster.local:389`
   - Base DN: `dc=authentik,dc=local`

## Backup

```bash
# Backup PostgreSQL database
kubectl exec -n wontlost-data postgres-0 -- pg_dump -U authentik authentik > authentik-backup.sql

# Backup Authentik media/flows (if customized)
kubectl exec -n authentik deployment/authentik-server -- tar czf /tmp/media.tar.gz /media
kubectl cp authentik/authentik-server-xxx:/tmp/media.tar.gz ./authentik-media-backup.tar.gz
```

## Troubleshooting

### Check Logs

```bash
# Server logs
kubectl logs -n authentik -l app.kubernetes.io/component=server -f

# Worker logs
kubectl logs -n authentik -l app.kubernetes.io/component=worker -f
```

### Database Connection Issues

```bash
# Test PostgreSQL connection from Authentik pod
kubectl exec -n authentik deployment/authentik-server -- \
  python -c "import psycopg2; print(psycopg2.connect('postgresql://authentik:password@host:5432/authentik'))"
```

### Redis Connection Issues

```bash
# Check Redis
kubectl exec -n authentik deployment/authentik-server -- \
  redis-cli -h authentik-redis-master ping
```
