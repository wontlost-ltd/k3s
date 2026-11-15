# k3s server 主机配置（apiserver 审计日志 / GitHub OIDC）运维手册

对应 aster-api ADR 0057 与计划 `docs/superpowers/plans/2026-11-16-k3s-apiserver-audit-and-probe-oidc.md`。所有节点操作都由用户经 ssh 执行；仓库只提供文件与脚本 `hosts/k3s-server/node.sh`。

## 1. 内容与约定

| 仓库文件（`hosts/k3s-server/files/…`） | 安装到节点 | 组件 |
|---|---|---|
| `etc/rancher/k3s/config.yaml.d/50-aster-audit.yaml` | 同路径 | `audit` |
| `etc/rancher/k3s/aster/audit-policy.yaml` | 同路径 | `audit` |
| `etc/rancher/k3s/config.yaml.d/60-aster-oidc.yaml` | 同路径 | `oidc` |
| `etc/rancher/k3s/aster/authentication-config.yaml` | 同路径 | `oidc` |

- 参数全部经 drop-in 以 `kube-apiserver-arg+:` **追加**，不改手写的 `/etc/rancher/k3s/config.yaml`。那个文件含 server token，**不要 cat、不要整份贴出**；`node.sh` 只按键名计数。
- 文件为 root 0600，`/etc/rancher/k3s/aster` 为 0700；审计日志写在 `/var/lib/rancher/k3s/server/logs/`（0700）；备份放在 `/var/lib/rancher/aster-host-backup/`。
- 只装在三台 control-plane（`master-1/2/3`）；`worker-1` 是 agent，不装。
- 节点（OCI 公网 IP，ssh 用户按实际情况，Oracle Linux 镜像缺省为 `opc`）：

| 节点 | 公网 IP | 内网 IP |
|---|---|---|
| master-1 | 158.179.18.241（也是探针与管理员 kubeconfig 的 API 地址） | 192.168.0.2 |
| master-2 | 152.69.183.104 | 192.168.0.3 |
| master-3 | 168.138.9.63 | 192.168.0.4 |

`node.sh` 子命令：`check`、`status`、`preflight <组件>`、`apply <组件> [--no-restart] [--no-auto-rollback]`、`verify <组件>`、`rollback <组件>`，组件为 `audit`、`oidc` 或 `audit,oidc`。退出码 0 成功；1 失败（apply 失败时已自动回滚）；2 用法错误；4 回滚也失败，需要人工处理（见 §5）。

## 2. 维护窗口前

1. k3s 仓的 PR 已合并，本地 `main` 是最新：`cd ~/IdeaProjects/k3s && git pull --ff-only`。
2. 窗口避开 **03:17 UTC**（探针定时运行）。master-1 重启的 1–3 分钟里，探针与管理员 kubeconfig 都连不上 API，这是预期现象。窗口期间**不要手动触发** `guard-bypass-probe`（`workflow_dispatch`），也不要合并会触发它的 PR（`apps/aster-lang/{agents,guard,tools}/**`、`scripts/guard-bypass/**`）。如果它在窗口内运行并以 3 退出，这是预期内的失败：窗口结束后执行 `gh workflow run guard-bypass-probe.yml -R wontlost-ltd/k3s --ref main` 重跑一次，确认变绿，否则 watchdog 的 36 小时口径会受影响。
3. 在 Mac 上执行：
   ```bash
   export KUBECONFIG=~/.kube/k3s-config
   kubectl get nodes                                   # 4 台 Ready
   kubectl get endpoints kubernetes -n default         # 恰为 3 个 IP：192.168.0.2/3/4
   ```
4. 在任一台 master 上做 etcd 快照（配置改动不碰 etcd，快照只是保险）：`sudo k3s etcd-snapshot save --name pre-aster-host`。
5. 把脚本分发到三台节点，再分别看 `status`：
   ```bash
   for h in 158.179.18.241 152.69.183.104 168.138.9.63; do
     tar -C hosts/k3s-server -czf - . | ssh opc@$h 'rm -rf ~/aster-host && mkdir -p ~/aster-host && tar -xzf - -C ~/aster-host'
   done
   ssh -t opc@158.179.18.241 'sudo NODE_NAME=master-1 bash ~/aster-host/node.sh status'
   ssh -t opc@152.69.183.104 'sudo NODE_NAME=master-2 bash ~/aster-host/node.sh status'
   ssh -t opc@168.138.9.63  'sudo NODE_NAME=master-3 bash ~/aster-host/node.sh status'
   ```
   期望：每台都是 `etcd：members=3 started=3 …`、端点 3 个、control-plane Ready 3 台。**记下哪台输出了「★本节点是 etcd leader」**，那台放在最后处理。
6. 在三台上执行 `sudo bash ~/aster-host/node.sh check`，都应以 0 退出。有 `fail` 先处理，尤其是 firewalld masquerade（§6）与冲突键。

## 3. 滚动安装（每次一台；先两台非 leader，leader 最后）

对每台节点 `N`（主机 `H`），依次执行：

```bash
ssh -t opc@H 'sudo NODE_NAME=N bash ~/aster-host/node.sh apply audit'
```

`apply` 会依次做：preflight（check、本节点 Ready、3 个端点、3 台 control-plane Ready、etcd 3 个成员都已启动且本机健康、可用空间 ≥ 2 GiB）→ 备份 → 安装 → `systemctl restart k3s` → 等就绪（最多 300 s：本地 `/readyz`、端点恢复为 3 个、本节点 Ready）→ verify（本次启动的 `Running kube-apiserver` 行带上了 `--audit-policy-file`、`audit.log` 在写）。任何一步失败都会自动回滚并以 1 退出。

**每台完成后、处理下一台之前**，在 Mac 上执行：

```bash
kubectl get nodes                                   # 4 台 Ready
kubectl get endpoints kubernetes -n default         # 3 个 IP
kubectl get --raw='/readyz?verbose' | tail -n 3     # readyz check passed
```

有任何一项不对就停下，不要处理下一台（另外两台还在，仲裁不受影响）。

三台都完成后，在每台上执行 `sudo bash ~/aster-host/node.sh check`，应输出 `installed  组件 audit` 且以 0 退出。

**OIDC 组件**按 aster-api ADR 0057 §7 的 M1 执行：先确认 k3s PR 已同步到集群，且 `vap-check.sh` 对两个身份全部符合（§7 / M0）。然后同样逐台执行 `node.sh apply oidc`。它的 preflight 额外要求本机能取到 GitHub 的发现文档与 JWKS，verify 额外要求参数行带 `--authentication-config`、本次启动的日志里没有 `oidc authenticator` 错误。之后修改 `authentication-config.yaml` 不需要重启：apiserver 每分钟自动重读，新内容无效时保留旧配置。但仍要用 `node.sh apply oidc --no-restart` 安装新文件，让 `check` 保持一致。

只想重启一轮时，可以执行 `apply audit,oidc`（ADR 0057 Q3）；代价是出问题时分不清是哪个组件导致的。

## 4. 核对审计日志

```bash
# 节点上：实际速率与占用（上线 24 h 后贴 #466）
sudo bash ~/aster-host/node.sh status
sudo ls -lh /var/lib/rancher/k3s/server/logs/
# 探针（SA 与 OIDC）调用；审计日志只记在处理该请求的那台 apiserver 上，还原完整调用要合并三台的结果
sudo sh -c 'zcat -f /var/lib/rancher/k3s/server/logs/audit*.log*' | python3 -c '
import json, sys
for line in sys.stdin:
    e = json.loads(line); u = e.get("user", {})
    if u.get("username") in ("system:serviceaccount:aster-guard:guard-bypass-probe", "github-actions:wontlost-ltd/k3s:guard-probe"):
        r = e.get("objectRef", {})
        print(e["requestReceivedTimestamp"], u.get("extra", {}).get("aster-lang.dev/gha-run-id", ["-"])[0], e["verb"],
              r.get("namespace", "-"), r.get("resource", "-"), r.get("name", "-"), e.get("responseStatus", {}).get("code"), e.get("sourceIPs"))'
```

- 日志可能含 Pod 规格（RequestResponse 级），**不要整份外传**；需要贴出时只贴上面这种摘要。
- 容量：按 ADR 0057 §3 的估算，每节点每天 90–260 MB 原始日志。20 份备份的份数上限先于 30 天到达，可保留约 8–22 天。磁盘占用预计约 0.5 GB（gzip 后，属估算），未压缩的硬上限约 2.1 GB。上线 24 小时后用 `status` 核对实际速率：偏离估算 2 倍以上，或保留天数低于 7 天，就调整 `50-aster-audit.yaml` 的 `audit-log-maxbackup`，走 PR 后再逐台 `apply audit`（策略文件不热加载，需要重启）。
- apiserver 延迟：在 Grafana 看 `histogram_quantile(0.99, sum by (le) (rate(apiserver_request_duration_seconds_bucket{verb!~"WATCH|CONNECT"}[10m])))`，安装前后各看一次。上升超过 20% 时，按 ADR 0057 §8 改为 `audit-log-mode=batch`。

## 5. 回滚

| 情况 | 动作 |
|---|---|
| 想撤掉某个组件（单台） | `sudo bash ~/aster-host/node.sh rollback audit`（或 `oidc`）：删除文件；有备份就恢复上一次 apply 之前的版本；然后重启并等待就绪 |
| `apply` 退出 1 | 已自动回滚且节点已就绪。看输出里的 `fail` 行与 `journalctl -u k3s -n 200`，排查清楚后再试 |
| `apply` 退出 4，或 k3s 起不来 | 人工处理：`sudo rm -f /etc/rancher/k3s/config.yaml.d/50-aster-audit.yaml /etc/rancher/k3s/config.yaml.d/60-aster-oidc.yaml && sudo systemctl restart k3s`，再 `journalctl -u k3s -n 200`。另外两台在，仲裁就在；**不要**同时去动另一台 |
| 三台都已安装，想整体撤销 | 逐台 `rollback`，顺序与安装相同 |

`--no-auto-rollback` 只用于排障：失败时保留现场，不自动回滚。

## 6. 主机配置漂移与 firewalld（#466 教训）

`node.sh check` 是只读的，可以随时运行；每次改主机配置、升级 k3s 或系统包之后都要跑一次。它检查：

- firewalld 在运行时，`trusted` 区的**运行时与永久配置**都不得开 masquerade。#466 中，跨节点 Pod 流量被伪装成节点地址，kube-router 的命名空间 ipset 匹配不上，被放行的路径也被丢弃，ADR 0054 §12.1 记录了这一点。只改运行时，下次 `firewall-cmd --reload` 就会复发，所以两处都要去掉：`sudo firewall-cmd --zone=trusted --remove-masquerade && sudo firewall-cmd --permanent --zone=trusted --remove-masquerade`。其它区开着 masquerade 只告警。
- 已安装的组件文件与仓库的 sha256 一致。不一致（`drift`）说明有人手改过：要么重新 `apply`，要么 `rollback`，不要原地编辑。
- `config.yaml` 与其它 drop-in 里没有 `audit-*`、`oidc-*`、`authentication-config` 键。`--oidc-*` 与 `--authentication-config` 同时出现时，apiserver 会直接退出。

新节点开通时不要加 `--add-masquerade`；装完 k3s 之后先跑一次 `check`。
