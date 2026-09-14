#!/bin/bash
# ★夹具（规则 1）：五个关键词族**各一行**，非真实凭据。
#   原夹具只有 PGPASSWORD 一行，于是把规则收窄成只认 PGPASSWORD
#   仍然全绿——规则宣称覆盖五族，实际只有一族被钉住（审计实测）。
#   刻意**不含** DSN：否则规则 2 会替规则 1 背书。
PGPASSWORD="Fixture-Not-Real-Pw-9x7Qz2" psql -h db.example -U admin
DB_PASSWD="Fixture-Not-Real-Passwd-3m5Kd" ./migrate.sh
MYSQL_PWD="Fixture-Not-Real-Pwd-8j2Wq" mysql -u root
APP_SECRET="Fixture-Not-Real-Secret-6h4Tz" ./boot.sh
GITEA_TOKEN="Fixture-Not-Real-Token-1v9Bn" ./sync.sh
