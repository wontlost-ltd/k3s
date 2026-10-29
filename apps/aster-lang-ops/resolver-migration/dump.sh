#!/bin/sh
# ADR 0051 §9 回滚点：迁移前把两库被迁移改写的表 pg_dump 到持久卷。
#
# 由 resolver-migration CronJob 的第一个 initContainer 执行（PG 16.4 客户端，与生产
# shared-postgres 同主版本）。只读：只跑 pg_dump / \copy TO / SELECT。
# 账号：aster_api 用迁移账号 aster_migrator（表 owner）——pg_dump 会读表自带序列的
# last_value，需要序列的 SELECT 权限，运行时账号 aster_api_user 不保证有（本地 PG 16 实测
# 缺该权限时 pg_dump 直接失败）；aster_cloud 用 aster-cloud-migrate 同一连接串（其账号即表 owner）。
#
# 产物（/backup/adr0051/<UTC 时间戳>/）：
#   aster_api.dump                   pg_dump -Fc：policy_versions + policy_artifacts（结构+数据，存档用）
#   aster_cloud.dump                 pg_dump -Fc："PolicyVersion" + "UserVocabularySnapshot"
#   api_policy_versions.csv 等 4 个  逐行 CSV（含表头），回滚时 \copy 进临时表再按 id UPDATE
#                                    ——这些表被大量外键引用，不能整表 DROP/TRUNCATE 后恢复
#   pending-before.txt               迁移前两库待迁移行数
#   SHA256SUMS                       以上文件的校验和
# 运行目录写入 /work/run-dir，供后续容器读取。
set -eu

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="/backup/adr0051/${STAMP}"
mkdir -p "$RUN_DIR"
printf '%s\n' "$RUN_DIR" > /work/run-dir
echo "[dump] run dir: $RUN_DIR"

# aster_api：连接串不含凭据（reactive-url），凭据（aster_migrator）走 PGUSER/PGPASSWORD，只对 api() 包裹的命令生效。
api() { PGUSER="$API_DB_USER" PGPASSWORD="$API_DB_PASSWORD" "$@"; }
# aster_cloud：DATABASE_URL 自带凭据（与 aster-cloud-migrate Job 同一 secret）。
API_URL="$API_DB_URL"
CLOUD_URL="$CLOUD_DATABASE_URL"

# 前置：新列必须已落地（aster-api Flyway V6.34.0；cloud drizzle 0060 + 0061）。
# 缺列说明发布尚未完成，此时跑迁移必然失败，直接拒绝。
api psql "$API_URL" -v ON_ERROR_STOP=1 -qAt -c \
  'SELECT resolver_version, resolver_migration_error, archived_by_resolver_migration, status_before_archive FROM policy_versions LIMIT 0' \
  || { echo "[dump] aster_api.policy_versions 缺少 resolver 列（V6.34.0 未落地？）" >&2; exit 2; }
psql "$CLOUD_URL" -v ON_ERROR_STOP=1 -qAt -c \
  'SELECT "sourceScopesJson", "resolverVersion", "resolverMigrationError", "archivedByResolverMigration", "statusBeforeArchive" FROM "PolicyVersion" LIMIT 0' \
  || { echo "[dump] aster_cloud.\"PolicyVersion\" 缺少 0060/0061 列（迁移未落地？）" >&2; exit 2; }

{
  printf 'aster_api policy_versions pending/total: '
  api psql "$API_URL" -v ON_ERROR_STOP=1 -qAt -F / -c \
    'SELECT count(*) FILTER (WHERE resolver_version IS DISTINCT FROM 1), count(*) FROM policy_versions'
  printf 'aster_cloud "PolicyVersion" pending/total: '
  psql "$CLOUD_URL" -v ON_ERROR_STOP=1 -qAt -F / -c \
    'SELECT count(*) FILTER (WHERE "resolverVersion" IS DISTINCT FROM 1), count(*) FROM "PolicyVersion"'
} > "$RUN_DIR/pending-before.txt"
# 不用 `| tee`：POSIX sh 没有 pipefail，管道会吞掉左侧 psql 的失败；先写文件（set -e 生效）再打印。
cat "$RUN_DIR/pending-before.txt"

api pg_dump --dbname="$API_URL" -Fc --no-owner --no-privileges \
  -t public.policy_versions -t public.policy_artifacts -f "$RUN_DIR/aster_api.dump"
pg_dump --dbname="$CLOUD_URL" -Fc --no-owner --no-privileges \
  -t 'public."PolicyVersion"' -t 'public."UserVocabularySnapshot"' -f "$RUN_DIR/aster_cloud.dump"

api psql "$API_URL" -v ON_ERROR_STOP=1 -q -c \
  "\\copy (SELECT * FROM policy_versions ORDER BY id) TO '$RUN_DIR/api_policy_versions.csv' WITH (FORMAT csv, HEADER)"
api psql "$API_URL" -v ON_ERROR_STOP=1 -q -c \
  "\\copy (SELECT * FROM policy_artifacts ORDER BY id) TO '$RUN_DIR/api_policy_artifacts.csv' WITH (FORMAT csv, HEADER)"
psql "$CLOUD_URL" -v ON_ERROR_STOP=1 -q -c \
  "\\copy (SELECT * FROM \"PolicyVersion\" ORDER BY id) TO '$RUN_DIR/cloud_PolicyVersion.csv' WITH (FORMAT csv, HEADER)"
psql "$CLOUD_URL" -v ON_ERROR_STOP=1 -q -c \
  "\\copy (SELECT * FROM \"UserVocabularySnapshot\" ORDER BY id) TO '$RUN_DIR/cloud_UserVocabularySnapshot.csv' WITH (FORMAT csv, HEADER)"

# 校验 -Fc 归档可读（目录可列出），防止写出半截文件仍继续迁移。
pg_restore --list "$RUN_DIR/aster_api.dump" > /dev/null
pg_restore --list "$RUN_DIR/aster_cloud.dump" > /dev/null

(cd "$RUN_DIR" && sha256sum aster_api.dump aster_cloud.dump ./*.csv pending-before.txt > SHA256SUMS)
ls -l "$RUN_DIR"
echo "[dump] done"
