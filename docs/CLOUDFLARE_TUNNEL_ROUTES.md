# Cloudflare Tunnel 路由清单

## 为什么需要这份文档

本集群的 cloudflared 以 **token 模式**运行（见
`apps/infrastructure/cloudflare-tunnel/deployment.yaml`，启动参数是
`tunnel run --token $(TUNNEL_TOKEN)`）。这种模式下 **ingress 规则存放在 Cloudflare 云端**，
由 dashboard 管理，**不在本仓库里**。

也就是说，仓库里的 GitOps 清单无法完整描述一个服务如何对外暴露：Deployment / Service /
Ingress 都在 git 中，但「哪个域名转发到哪个 Service」这一环只存在于 Cloudflare 控制台。
tunnel 若需重建，或有人想弄清某个域名的流量走向，这里就是唯一的书面记录。

**新增或修改路由后，请同步更新本文件。**

## 当前路由

在 Cloudflare Zero Trust → Networks → Tunnels → **MEL_OCI_K3S** → Public Hostname 下配置。

| 域名 | Service（Type + URL） | 对应应用 |
|---|---|---|
| `ckeditor-builder.wontlost.com` | `http://ckeditor-builder.wontlost-ckeditor-builder.svc.cluster.local:80` | `apps/wontlost/ckeditor-builder` |
| `sentinel-ops.wontlost.com` | `http://sentinel-ops.wontlost-sentinel-ops.svc.cluster.local:80` | `apps/wontlost/sentinel-ops` |

Tunnel ID：`7a86c1b5-5b7b-484e-9203-7df53026b076`
（DNS 侧表现为 CNAME → `<tunnel-id>.cfargotunnel.com`，proxied。）

## 两个容易踩的点

**一、tunnel 直连 Service，不经 Traefik。**

上表的 URL 指向应用自己的 Service，流量不经过 Traefik。这有两个后果：

- NetworkPolicy 的入站来源必须是 **`cloudflare` namespace**（cloudflared 所在），
  写成 `kube-system`（Traefik）会导致 502。
- 应用的 Ingress 对象仍然保留且有效，但它服务的是集群内访问或将来切回 Traefik 的场景，
  不是当前的公网路径。

**二、DNS 记录交给 dashboard 创建，不要手工先建。**

在 dashboard 添加 public hostname 时，Cloudflare 会自动创建对应的 CNAME。若事先手工建了同名
记录，添加时会报 `A DNS record with this name already exists.`，必须先删掉手工记录。

删除再重建的过程中，各级解析器会缓存「该域名无记录」的空应答（负缓存），造成几分钟内
无法访问 —— 权威 TTL 约 141 秒，等待即可自行恢复。**正确顺序是：先在 dashboard 配 public
hostname，让它自动建 DNS 记录。**

## 新增一个对外服务的完整步骤

1. 在 `apps/wontlost/<app>/` 下放置清单（namespace / deployment / service / ingress /
   kustomization）。ApplicationSet 会自动发现 `apps/wontlost/*/kustomization.yaml`，
   无需手工注册 Application。
2. **在 `argocd/projects/wontlost.yaml` 的 `destinations` 里加上新 namespace。**
   该列表是显式列举、刻意不用通配符；漏掉这步 ArgoCD 会拒绝同步并报
   `... do not match any of the allowed destinations in project 'wontlost'`。
3. 镜像必须 digest 固定，否则 `verify-no-floating-tags` 会拦下 PR。首次引入时也不能用
   无 digest 的占位 tag。
4. 合并后确认 pod 起来、`kubectl -n <ns> get application` 为 `Synced/Healthy`。
5. 最后在 Cloudflare dashboard 添加 public hostname（见上文顺序说明），并更新本文件。
