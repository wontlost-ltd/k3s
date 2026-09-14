#!/bin/bash
# ★夹具（规则 1：环境变量赋明文）：非真实凭据，随机生成。
#   刻意**不含** DSN——否则规则 2 会替规则 1 背书，
#   使得单独废掉规则 1 时本夹具仍被抓到（实测踩过）。
PGPASSWORD="Fixture-Not-Real-Pw-9x7Qz2" psql -h db.example -U admin
