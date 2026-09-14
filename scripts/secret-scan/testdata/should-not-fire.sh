#!/bin/bash
# ★夹具：全部是**合法**写法，规则不得误报。
PGPASSWORD="${PGPASSWORD:?missing}" psql -h db
DB_PASSWORD="$(openssl rand -base64 24)"
DSN="postgres://app:${PGPASSWORD}@db:5432/app"
API_TOKEN="your-token-here"
