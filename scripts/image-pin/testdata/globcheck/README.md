# glob 匹配复算（S2-0 CIP 契约实证）

本目录固化 policy-controller CIP `images.glob` 匹配语义的可复现实证，佐证
`docs/p0a-s2-0-cosign-admission-design.md` §6 的 glob 定案（`@sha256:**`）。

## 上游来源（固定版本）
- 仓库：github.com/sigstore/policy-controller
- tag：v0.13.1（= helm chart sigstore/policy-controller 0.10.6 的 appVersion）
- 文件：`pkg/apis/glob/glob.go`（`Compile` 函数）
- 提交时复制其 `Compile` 正则翻译逻辑（`.`→`\.`、`**`→`.*`、`*`→`[^/]*`、`^…$` 全串锚定）。

## 运行
    cd scripts/image-pin/testdata/globcheck
    go test -v ./...

失败返回非零。测试表驱动，覆盖 aster-api + aster-cloud-migrate 两仓、
三种等价 digest 引用（docker.io / index.docker.io / 短名）、tag 形式、
前缀误纳（aster-api-malicious）、别 registry，以及 **tag-fail CIP 的
`:**` glob 命中「仍为 tag 形式」的镜像**（TOCTOU 闭合，见设计文档 §6）。

## 关于 `normalizeName` 的手写近似
本测试的 `normalizeName` 手写复制 go-containerregistry `name.ParseReference().Name()`
对 Docker Hub 的规范化（docker.io/短名→index.docker.io；带 digest 时 Name()
丢弃 tag），**未直接依赖上游 go-containerregistry 包**（避免额外依赖 + 沙箱
network 限制）。近似范围仅限本测试输入涉及的镜像形态（受控两仓的 digest/tag/
前缀/别 registry），对这些输入与上游行为等价。**更强做法（实现时可选）**：固定
真实 go-containerregistry 依赖并直接调 `name.ParseReference`，防近似未来漂移。
staging 用 policy-controller 自带 `policy-tester`（同 chart appVersion）真跑复验。
