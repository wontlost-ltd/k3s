#!/bin/bash
# Setup PostgreSQL Hyperdrive using Wrangler CLI
# This is the recommended approach for creating Hyperdrive configurations

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

echo "=========================================="
echo "  PostgreSQL Hyperdrive Setup (Wrangler)"
echo "=========================================="
echo ""

# 允许未设：由下面的守卫给出可操作的报错，而不是 set -u 的 unbound variable
PG_PASSWORD="${PG_PASSWORD:-}"

# ★PG_PASSWORD 必须由环境提供（此前硬编码在本文件，随 public 仓泄露）。
#   空值会拼出一个无密码的连接串并静默失败，故先 fail-loud。
#   取值来源：Vault data-services/aster-api-db（与 ExternalSecret 同源）。
if [[ -z "$PG_PASSWORD" ]]; then
    log_warn "PG_PASSWORD environment variable is not set"
    log_info "Get it from Vault: vault kv get -field=password data-services/aster-api-db"
    log_info "Then: export PG_PASSWORD=<value>"
    exit 1
fi

# Check if wrangler is installed
if ! command -v wrangler &> /dev/null; then
    log_warn "wrangler CLI not found. Installing..."
    npm install -g wrangler
fi

# Check if logged in
log_step "Step 1: Checking Wrangler authentication..."
if ! wrangler whoami &> /dev/null; then
    log_info "Please login to Cloudflare:"
    wrangler login
fi

echo ""
log_step "Step 2: Creating Hyperdrive configuration..."
echo ""

# Connection details
PG_HOST="postgres-tunnel-svc.data-services.svc.cluster.local"
PG_PORT="5432"
PG_DATABASE="aster_api"
PG_USER="aster_api_user"

# Build connection string
CONNECTION_STRING="postgresql://${PG_USER}:${PG_PASSWORD}@${PG_HOST}:${PG_PORT}/${PG_DATABASE}?sslmode=disable"

log_info "Creating Hyperdrive 'aster-api-postgres'..."
log_info "Host: ${PG_HOST}"
log_info "Database: ${PG_DATABASE}"
log_info "User: ${PG_USER}"
echo ""

# Create Hyperdrive
# Note: --caching-disabled=false is default (caching enabled)
wrangler hyperdrive create aster-api-postgres \
    --connection-string="${CONNECTION_STRING}" \
    2>&1 || {
        log_warn "Hyperdrive might already exist. Listing existing configs..."
        wrangler hyperdrive list
    }

echo ""
log_step "Step 3: Listing Hyperdrive configurations..."
wrangler hyperdrive list

echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo ""
echo "1. Add private network route in Cloudflare Zero Trust Dashboard:"
echo "   - Go to: https://one.dash.cloudflare.com"
echo "   - Networks > Tunnels > Select your tunnel"
echo "   - Private Network tab > Add route:"
echo "     CIDR: 10.43.0.0/16"
echo "     Comment: k3s Service network for Hyperdrive"
echo ""
echo "2. Deploy K8s manifests:"
echo "   argocd app sync postgres-cluster"
echo ""
echo "3. Get your Hyperdrive connection string:"
echo "   wrangler hyperdrive get aster-api-postgres"
echo ""
echo "4. Add to Vercel environment variables:"
echo "   DATABASE_URL=<hyperdrive-connection-string>"
echo ""
