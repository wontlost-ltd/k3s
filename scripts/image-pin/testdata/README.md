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
前缀误纳（aster-api-malicious）、别 registry。
