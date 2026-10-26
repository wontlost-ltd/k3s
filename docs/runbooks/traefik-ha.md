# Traefik 高可用改造（k3s 内置 Traefik）

> 背景：2026-10-26 生产压测中，匿名读路径在约 150 RPS 后雪崩。根因是 Traefik **单副本且未设 requests（BestEffort QoS）**，与 aster-api、Redis 同挤在 1 vCPU 的 master-3 上；负载上来后 readiness 探针 `/ping` 超时（默认 1-2s）被摘除 Endpoints，cloudflared 直接被拒连（`dial tcp <traefik ClusterIP>:443: connect: connection refused` → 502）。详见 aster-api `docs/perf/prod-loadtest-20261026.md`。

## 为什么不走 ArgoCD

`kube-system/traefik` 的 `HelmChartConfig` 由 k3s 的 `Addon` 对象 `traefik-config` 生成（`objectset.rio.cattle.io/owner-name: traefik-config`），来源是 master 节点上的
`/var/lib/rancher/k3s/server/manifests/traefik-config.yaml`。k3s 会在重启或文件变更时按该文件**重新覆盖** HelmChartConfig；若由 ArgoCD 管理同一对象，两个控制器会互相覆盖。因此只能改节点上的这个文件。

## 目标配置

修改 **master-1** 上的 `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml`（2026-10-26 核实：只有 master-1 有该文件，master-2/3 没有；不要在其他 master 上新建，单一来源可避免多个 server 用不同内容互相覆盖。HelmChartConfig 对象本身存于 etcd，master-1 宕机也不会丢失）。

注意：同目录下的 `traefik.yaml` 是 k3s 内置 HelmChart，**每次 k3s 启动都会被重写，不要修改**；`traefik-config.yaml` 的 values 会与其深度合并，原有的 podAnnotations、priorityClassName、tolerations 等保持不变。

目标内容：

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    additionalArguments:
      - "--providers.kubernetesingress.ingressendpoint.publishedservice=kube-system/traefik"
    globalArguments:
      - "--serversTransport.insecureSkipVerify=true"
    tlsStore:
      default:
        defaultCertificate:
          secretName: wildcard-ezymeta-com-tls
    # —— 以下为本次新增 ——
    # 2 副本：全集群唯一入口，单副本即单点。
    deployment:
      replicas: 2
    # 设 requests 使其脱离 BestEffort：调度时预留 CPU，节点压力下不再最先被饿死/驱逐。
    # 4×1 OCPU 免费额度下 requests 取 100m（总计 +200m）；节点扩容后可提到 200m。
    resources:
      requests:
        cpu: 100m
        memory: 64Mi
      limits:
        cpu: 500m
        memory: 256Mi
    # 节点排空/升级时至少保留 1 个副本。
    podDisruptionBudget:
      enabled: true
      minAvailable: 1
    # 两个副本尽量分布在不同节点（软约束）。
    affinity:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  app.kubernetes.io/name: traefik
                  app.kubernetes.io/instance: traefik-kube-system
    # 放宽 readiness：短暂 CPU 争用时不立刻摘除 Endpoints（压测中正是探针超时导致 502）。
    readinessProbe:
      timeoutSeconds: 5
      periodSeconds: 10
      failureThreshold: 3
```

## 操作步骤

1. 在 master-1 上备份：`cp /var/lib/rancher/k3s/server/manifests/traefik-config.yaml /root/traefik-config.yaml.bak-$(date +%Y%m%d)`。
2. 在 master-1 写入上面的内容。k3s 会自动重新应用 HelmChartConfig，helm-controller 随即 `helm upgrade` Traefik（无需重启 k3s）。
3. 观察：
   ```bash
   kubectl -n kube-system get jobs | grep helm-install-traefik     # 最新一次 Completed
   kubectl -n kube-system get deploy traefik                       # READY 2/2
   kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik -o wide   # 两个副本在不同节点
   kubectl -n kube-system get pdb traefik
   ```
4. 冒烟：`curl -s -o /dev/null -w '%{http_code}\n' https://policy.aster-lang.dev/api/v1/lexicons` 与 `https://aster-lang.cloud/` 均为 200。

## 回滚

把备份文件拷回 master-1 的同一路径即可；helm-controller 会回到单副本配置。

## 容量说明

本次只为 Traefik 增加 2×100m CPU requests。当前集群为 OCI Always Free 额度（4×VM.Standard.A1.Flex，各 1 OCPU / 6GB），CPU requests 已占约 80%，若第二个副本因资源不足处于 Pending，先确认 aster-api 已按新 HPA 缩回 2 副本（释放 requests），再检查 `kubectl describe pod` 的调度事件。
