#!/bin/bash
# ★夹具（规则 2）：六个 scheme **各一行**，非真实凭据。
#   原夹具只有 postgres 一行，于是把 scheme 列表收窄成只剩 postgres
#   仍然全绿——与规则 1 的「只有 PGPASSWORD 一族」是同一种夹具塌缩，
#   在紧挨着的规则里原样复发（复审实测）。
DSN_PG="postgres://svc:Fixture-Not-Real-Pg-4k8Mn@db.example:5432/app"
DSN_PGSQL="postgresql://svc:Fixture-Not-Real-Pgsql-7h2Qr@db.example:5432/app"
DSN_MYSQL="mysql://svc:Fixture-Not-Real-My-2n6Vt@db.example:3306/app"
DSN_MONGO="mongodb://svc:Fixture-Not-Real-Mongo-9x3Lp@db.example:27017/app"
DSN_REDIS="redis://svc:Fixture-Not-Real-Redis-5c8Kj@cache.example:6379/0"
DSN_AMQP="amqp://svc:Fixture-Not-Real-Amqp-1z7Wd@mq.example:5672/vhost"
