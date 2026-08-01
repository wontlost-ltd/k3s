# monitoring —— Prometheus / Alertmanager / Grafana

## ⚠️ 首要原则：告警系统自身没有带外监控

Alertmanager 送不出告警时，**唯一的症状是它自己产生的 `AlertmanagerFailedToSendAlerts`
告警——而那条告警同样送不出去**。Watchdog 也走同一条链路。

所以：**改动任何与通知相关的配置后，必须实测「告警真的送达」，不能只看 Pod 是 Running**。

2026-08-01 事故即由此而来：Slack 通道从 07-28 起完全失效，**3 天无人知晓**，
期间漏掉一条 critical（`AsterApiSlaBreachDay`，24h 可用率 99.09%）。

## Slack webhook 的格式约束

`alertmanager-slack-webhook` 这个 Secret 的 `url` 键（来自 Vault
`secret/apps/aster-api-plan-gate` 的 `slack-webhook` 属性）**必须是 Incoming Webhook URL**：

```
https://hooks.slack.com/services/T…/B…/…      ✅ 正确
xapp-1-A0…                                    ❌ app-level token，无法 POST
xoxb-…                                        ❌ bot token，需走 chat.postMessage API
```

事故根因就是此处存了 `xapp-1-…`。Alertmanager 的 `slack_api_url_file` 只接受
webhook URL；给它 token 会持续 `Notify attempt failed` 但**不会**让 Pod 不健康。

### 更换 webhook

```bash
# 1) 在 Slack 创建 Incoming Webhook（Apps → Incoming Webhooks → Add to Workspace）
# 2) 写入 Vault（★保留同路径下的 hmac-key，KV-v2 是整体替换）
vault kv patch secret/apps/aster-api-plan-gate slack-webhook='https://hooks.slack.com/services/...'

# 3) 催 ExternalSecret 刷新（否则等 1h）
kubectl annotate externalsecret -n monitoring alertmanager-slack-webhook \
  force-sync=$(date +%s) --overwrite

# 4) 确认 Secret 已更新为 hooks.slack.com 形态
kubectl get secret -n monitoring alertmanager-slack-webhook \
  -o jsonpath='{.data.url}' | base64 -d | cut -c1-30
```

> ★ 用 `vault kv patch` 而非 `put`：该路径下还有 `hmac-key` 被
> `aster-api-plan-gate-credentials` 消费，`put` 会把它抹掉。

## ★ 验证告警真的送达（改完必做）

只看 `Pod Running` 或 `/-/healthy` **不足以证明通道可用**——事故期间两者都是正常的。

```bash
# 1) 看有没有发送失败（最直接的证据）
kubectl logs -n monitoring alertmanager-prometheus-kube-prometheus-alertmanager-0 \
  -c alertmanager --tail=100 | grep -iE 'Notify attempt failed|Notify for alerts failed'
#    → 无输出才算通过

# 2) 确认没有 AlertmanagerFailedToSendAlerts 在活跃
kubectl exec -n monitoring alertmanager-prometheus-kube-prometheus-alertmanager-0 \
  -c alertmanager -- wget -qO- http://127.0.0.1:9093/api/v2/alerts \
  | jq -r '.[].labels.alertname' | sort -u

# 3) 端到端：注入一条测试告警，确认 Slack 频道真的收到
kubectl exec -n monitoring alertmanager-prometheus-kube-prometheus-alertmanager-0 \
  -c alertmanager -- wget -qO- --post-data='[{"labels":{"alertname":"ManualSmokeTest","severity":"warning"}}]' \
  --header='Content-Type: application/json' http://127.0.0.1:9093/api/v2/alerts
#    → 然后去 Slack 频道确认。这一步不可省略：前两步只能证明"没报错"，
#      而事故形态恰恰是"配置错了但不报错"。
```

## 资源配置

`alertmanagerSpec.resources.limits.memory` 曾设为 `128Mi`，实测导致
**78 天内 OOMKilled 539 次（≈7 次/天）**。常驻用量约 63Mi，但告警风暴与重试队列
会冲破上限；OOM 期间到达的通知直接丢失，重启后 Pod 自报健康、无任何残留信号。

现为 `256Mi`。若再出现 OOM，先看 `container_memory_working_set_bytes` 而不是直接调大：
持续增长通常意味着通知积压（发送端故障），调大只是推迟症状。

同 Pod 的 `config-reloader` 未声明 limits（chart 默认），实测约 16Mi。
