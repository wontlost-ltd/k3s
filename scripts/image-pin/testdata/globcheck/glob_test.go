// S2-0 CIP glob 匹配契约复算测试。
//
// 目的：证明 policy-controller CIP `images.glob = index.docker.io/<repo>@sha256:**`
// 只命中三种等价 digest 引用（docker.io / index.docker.io / 短名），不误纳前缀
// 仓库、不命中别 registry。佐证设计文档 §6 的 glob 定案。
//
// compileGlob 逐字复制 policy-controller v0.13.1 pkg/apis/glob/glob.go 的 Compile
// 正则翻译逻辑；normalizeName 复制 go-containerregistry name.ParseReference().Name()
// 对 Docker Hub 的规范化（docker.io / 短名 → index.docker.io）。
package globcheck

import (
	"regexp"
	"strings"
	"testing"
)

// compileGlob 复制 policy-controller glob.Compile 的正则翻译（上游 v0.13.1）。
func compileGlob(glob string) *regexp.Regexp {
	if glob == "*/*" {
		glob = "index.docker.io/*/*"
	}
	if glob == "*" {
		glob = "index.docker.io/library/*"
	}
	glob = strings.ReplaceAll(glob, ".", `\.`)
	glob = strings.ReplaceAll(glob, "**", "#")
	glob = strings.ReplaceAll(glob, "*", "[^/]*")
	glob = strings.ReplaceAll(glob, "#", ".*")
	return regexp.MustCompile("^" + glob + "$")
}

// normalizeName 复制 go-containerregistry 对镜像引用的规范化：
// docker.io / 无 registry 短名 → index.docker.io；带 registry（含 '.'）保留；
// digest / tag 保留；三种等价 digest 引用归一到同一 Name()。
func normalizeName(image string) string {
	var host, rest string
	switch {
	case strings.HasPrefix(image, "index.docker.io/"):
		host, rest = "index.docker.io", image[len("index.docker.io/"):]
	case strings.HasPrefix(image, "docker.io/"):
		host, rest = "index.docker.io", image[len("docker.io/"):]
	default:
		first := strings.SplitN(image, "/", 2)
		if len(first) == 2 && strings.Contains(first[0], ".") {
			host, rest = first[0], first[1] // 别 registry，如 ghcr.io
		} else {
			host, rest = "index.docker.io", image // 短名
		}
	}
	full := host + "/" + rest
	// 无 tag、无 digest → 假设 :latest（与上游一致）
	repo := strings.SplitN(full, "@", 2)[0]
	lastSeg := repo[strings.LastIndex(repo, "/")+1:]
	if !strings.Contains(full, "@") && !strings.Contains(lastSeg, ":") {
		full += ":latest"
	}
	// 带 digest 时，规范 Name() 丢弃 tag：repo:tag@sha256 → repo@sha256
	if i := strings.Index(full, "@"); i >= 0 {
		base := full[:i]
		if c := strings.LastIndex(base, ":"); c > strings.LastIndex(base, "/") {
			base = base[:c] // 去掉 tag 段
		}
		full = base + full[i:]
	}
	return full
}

const digest = "@sha256:1111111111111111111111111111111111111111111111111111111111111111"

func TestCIPGlobContract(t *testing.T) {
	type repoCase struct {
		repo string // 信任根 repository
		glob string // 定案 CIP glob
	}
	repos := []repoCase{
		{"wontlost/aster-api", "index.docker.io/wontlost/aster-api@sha256:**"},
		{"wontlost/aster-cloud-migrate", "index.docker.io/wontlost/aster-cloud-migrate@sha256:**"},
	}

	for _, rc := range repos {
		rc := rc
		t.Run(rc.repo, func(t *testing.T) {
			re := compileGlob(rc.glob)
			match := func(image string) bool {
				return re.MatchString(normalizeName(image))
			}

			// 应命中：三种等价 digest 引用（同一 Name()）。
			shouldMatch := []string{
				"docker.io/" + rc.repo + digest,
				"index.docker.io/" + rc.repo + digest,
				rc.repo + digest, // 短名
			}
			for _, img := range shouldMatch {
				if !match(img) {
					t.Errorf("应命中但未命中: %s (Name=%s)", img, normalizeName(img))
				}
			}

			// 不应命中：tag 形式（提交态；运行时由 Mutating webhook 解析为 digest
			// 后才由 Validating 命中——见 §6）、前缀误纳、别 registry。
			shouldNotMatch := []string{
				"docker.io/" + rc.repo + ":jvm-latest",       // 裸 tag（未解析）
				"docker.io/" + rc.repo + "-malicious" + digest, // 前缀误纳
				"ghcr.io/" + rc.repo + digest,                  // 别 registry
			}
			for _, img := range shouldNotMatch {
				if match(img) {
					t.Errorf("不应命中却命中: %s (Name=%s)", img, normalizeName(img))
				}
			}
		})
	}
}

// TestBareRepoGlobMatchesNothing 佐证：裸 repo 串（无 wildcard）匹配不了 digest 引用。
func TestBareRepoGlobMatchesNothing(t *testing.T) {
	re := compileGlob("index.docker.io/wontlost/aster-api")
	if re.MatchString(normalizeName("docker.io/wontlost/aster-api" + digest)) {
		t.Error("裸 repo glob 不应匹配 digest 引用")
	}
}

// TestTailStarGlobOvermatchesPrefix 佐证：尾部裸 ** 会误纳前缀仓库（故禁用）。
func TestTailStarGlobOvermatchesPrefix(t *testing.T) {
	re := compileGlob("index.docker.io/wontlost/aster-api**")
	if !re.MatchString(normalizeName("docker.io/wontlost/aster-api-malicious" + digest)) {
		t.Error("尾部 ** glob 预期误纳 aster-api-malicious（本测试记录该风险，故设计用 @sha256:**）")
	}
}
