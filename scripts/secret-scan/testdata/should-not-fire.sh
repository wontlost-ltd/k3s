#!/bin/bash
# ★夹具（反向）：**必须能被基础正则命中**，否则测的不是 allowlist。
#
#   复审实测：原夹具 5 行里有 3 行的值以 `$` 开头，而规则 1 的值字符类是
#   `[^"'\s$]`——它们在正则阶段就 nomatch，allowlist 对它们是死条款。
#   于是「反向夹具覆盖 4 种机制」实为只激活 1 种（第七处夹具塌缩）。
#   现在每一行都不含 `$`，确保真正走到 allowlist 才被豁免。

# ① 占位符族（your- / changeme / placeholder…）
API_TOKEN="your-token-here"
DB_PASSWORD="changeme-before-deploy"
# ② K8s Secret 引用（valueFrom / secretKeyRef）——值本身无 $，靠 allowlist 豁免
APP_SECRET="valueFrom-pg-creds-ref"
PGPASSWORD="secretKeyRef-vault-managed"
# ③ 全大写常量名当值（多为变量名而非密码）
MYSQL_PWD="DATABASE_PASSWORD"
