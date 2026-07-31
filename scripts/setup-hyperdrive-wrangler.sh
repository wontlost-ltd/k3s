#!/bin/bash
#
# ═══ PG 密码轮换 runbook（★Hyperdrive 是唯一需要手工的一环）═══
#
# 背景：Vault 轮换后，下列环节**自动**拿到新密码——
#   Vault data-services/aster-api-db
#     → ExternalSecret（refreshInterval: 1h）
#       → data-services/aster-api-postgres-credentials
#           → CloudNativePG managed role `aster_api_user`（自动 ALTER ROLE）
#       → aster-cloud ns/aster-api-db-credentials → aster-api Pod 环境变量
#
# 但 **Cloudflare Hyperdrive 例外**：它把含密码的连接串存在 Cloudflare 侧、不读 Vault。
# 不更新它，aster-cloud 经 Hyperdrive 的请求会开始认证失败，且无任何"配置过期"告警。
#
# 顺序（第 2 步紧跟第 1 步，把不可避免的窗口压到几分钟）：
#   1) vault kv put data-services/aster-api-db password=<新密码>
#   2) export PG_PASSWORD='<新密码>'
#      export CF_API_TOKEN='<Hyperdrive:Edit>'
#      ./scripts/setup-postgres-hyperdrive.sh    # ★用 API 版，不是本脚本
#   3) 触发/等待 ExternalSecret 刷新，确认 CNPG 已改库内密码
#   4) 验证：kubectl -n aster-cloud logs -l app=aster-api --tail=50 | grep -i auth
#
# Setup PostgreSQL Hyperdrive using Wrangler CLI
#
# ★仅用于**首次创建**。轮换密码/改 origin 请用 setup-postgres-hyperdrive.sh（API 版），
#   原因见下方 create-only 处的注释（连接串无法携带 Cloudflare Access 凭据）。

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

log_info "Host: ${PG_HOST}"
log_info "Database: ${PG_DATABASE}"
log_info "User: ${PG_USER}"
echo ""

# ★幂等 upsert（2026-07-31）：给了 HYPERDRIVE_ID 就更新，否则创建。
#
# 为什么必须支持更新：Hyperdrive 把**含密码的连接串存在 Cloudflare 侧**，不读 Vault。
# 所以轮换 PG 密码后，ExternalSecret 会把新密码下发给 CNPG 与 aster-api Pod，
# 但 Hyperdrive 里仍是旧连接串 → aster-cloud 经 Hyperdrive 的请求开始认证失败，
# 而**没有任何一处会报"配置过期"**。原实现只有 create，已存在时仅 list 一下就过去，
# 于是轮换后只能手敲 wrangler update + 记 ID。
#
# 为什么用显式 ID 而不是解析 `wrangler hyperdrive list`：该命令输出是带颜色和图标的
# 人类可读文本、无 --json 标志，解析它既脆又会随 wrangler 版本变化。
# ID 是稳定值，已记录在 aster-cloud 的 wrangler.toml（[[hyperdrive]] id = ...）。
# ★本脚本**不支持更新**，已存在时直接停（2026-07-31）。
#
# 为什么不像 setup-postgres-hyperdrive.sh 那样支持 update：
# `wrangler hyperdrive update` 只接受 --connection-string，而连接串**表达不了**
# 线上 origin 的 access_client_id（Cloudflare Access service token）。
# 实测线上 origin 就带 Access（host=postgres.aster-lang.dev 走 Tunnel），
# 用连接串整体覆盖会把 Access 凭据清空 → 生产直接断连。
# 相比之下 API 版只传 password，Cloudflare 会**合并**而非替换 origin，其余字段原样保留。
#
# 所以：**轮换密码请用 API 版脚本** `./scripts/setup-postgres-hyperdrive.sh`，
# 它会先读回线上 origin、只替换 password、其余字段原样回填。
if [[ -n "${HYPERDRIVE_ID:-}" ]] || wrangler hyperdrive list 2>/dev/null | grep -q 'aster-api-postgres'; then
    log_warn "检测到 Hyperdrive 'aster-api-postgres' 已存在。"
    log_warn "本脚本只能创建、不能安全更新（连接串无法携带 Access 凭据）。"
    log_warn "轮换密码请改用: CF_API_TOKEN=... PG_PASSWORD=... ./scripts/setup-postgres-hyperdrive.sh"
    exit 1
fi

log_step "创建 Hyperdrive 'aster-api-postgres'..."
wrangler hyperdrive create aster-api-postgres \
    --connection-string="${CONNECTION_STRING}"

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
