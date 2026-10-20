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
| `ai.aster-lang.cloud` | `http://aster-ai-workspace.aster-ai.svc.cluster.local:80` | `apps/aster-lang/ai` |

Tunnel ID：`7a86c1b5-5b7b-484e-9203-7df53026b076`
（DNS 侧表现为 CNAME → `<tunnel-id>.cfargotunnel.com`，proxied。）

## ai.aster-lang.cloud（AI 工作台，ADR 0049 Part D）的上线说明

该路由需在 dashboard **手工添加**（Type `HTTP`，URL
`aster-ai-workspace.aster-ai.svc.cluster.local:80`），且应在下列前置都完成、pod 就绪之后再加：

1. `.github/image-pin/allowed-images.yaml` 已加 `docker.io/wontlost/aster-ai-workspace` 信任根条目
   （受 ruleset 保护，只走人工 PR；缺它时 `verify-cip-sync.sh` 报 CIP 数量漂移）。
2. Vault 已写入以下两个路径（KV-v2 挂载点 `secret/`，`put` 为整体替换，须一次写全）：

   | Vault 路径 | 键 | 用途 |
   |---|---|---|
   | `secret/apps/aster-ai-workspace` | `hmac-key` | 服务 → cloud 请求签名，与 cloud 的 `AI_WORKSPACE_HMAC_KEY` 同值 |
   | | `handoff-public-key` | 交接令牌 Ed25519 公钥（base64 X.509 DER），与 cloud 的 `AI_WORKSPACE_HANDOFF_PRIVATE_KEY` 成对 |
   | | `ticket-key` | run 票据签名密钥，仅服务内部使用 |
   | | `pro-license` | AG-UI Pro license；暂无时写空串（服务降级为基础聊天） |
   | `secret/data-services/aster-ai-db` | `username` | 固定为 `aster_ai_user` |
   | | `password` | CNPG 角色密码，同时被 `aster-ai` 命名空间的应用读取 |

3. `aster_cloud` 库已建 `ai_workspace` schema（SQL 见
   `apps/infrastructure/postgres-cluster/manifests/cluster.yaml` 中 `aster_ai_user` 的注释）。
4. 源仓 main 首次 CI 构建签名后，image-pin PR 已把 `apps/aster-lang/ai` 的占位 digest 换成真值。

公网流量经 tunnel 直连 Service，不经 Traefik；`apps/aster-lang/ai/ingress.yaml`
只服务集群内访问。cloud 侧以 `NEXT_PUBLIC_AI_WORKSPACE_URL=https://ai.aster-lang.cloud`
接入（未设置时 cloud 保持旧面板）。

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
