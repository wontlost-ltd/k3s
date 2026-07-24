#!/usr/bin/env bash
# verify-runner-topology —— runner go-live 拓扑迁移专用校验器（strict pin 门的受控例外）
#
# 背景：launcher go-live PR（人工）需要「激活」已 pin 好的 launcher——把 deployment.yaml +
#   external-secrets.yaml 加入 kustomization resources、replicas 0→1、删 deploy-policy 的 launcher
#   deferred 豁免。这类 PR 碰 kustomization/deployment，会被 image-pin strict lane 的 check-pr-shape
#   拒（要 Bot 作者+image-pin/* 分支+改 image-lock）。本 lane 为其放行，但**绝不**成为绕过 pin 强制的通道。
#
# ★安全模型（Codex 两轮红队后重设计——**闭世界 canonical render-diff**，非字段黑名单）：
#   拓扑 lane 不得改变任何 pin 数据，也不得改变最终渲染出的**任何对象**（除「激活已固定 launcher
#   workload」这一唯一授权迁移）。字段级黑名单会漏 kustomize patches/replacements/transformers/
#   generators 及既有 resource 文件内容篡改（role.yaml 提权等）。故本校验器**渲染两侧全树**，逐对象
#   canonical 比对：
#     (A) base 渲染的**每个既有对象**必须在 head 渲染中逐字节不变（堵 role.yaml/rolebinding 等提权 +
#         patches/transformer 对既有对象的任何篡改——因为它们改的是**渲染结果**）。
#     (B) head 渲染**新增的对象**恰为 {Deployment/runner-launcher, ExternalSecret/hmac}，且各自逐字段
#         满足可信预期（image==launcher@base-pinned / replicas==1 / RUNNER_IMAGE_DIGEST==base runner
#         digest / 无额外容器 command args / HMAC 引用精确 / ExternalSecret 字段精确）。
#     (C) pin 真相文件（image-lock.yaml）+ pin transformer（kustomization.images）base==head 精确不变。
#     (D) deploy-policy 恰删 launcher deferred 一条。
#     (E) kustomization 除 resources delta 外**整体** canonical 相等（堵一切 transformer 字段）。
#   所有输入先过**严格 YAML 解析**（拒重复键/多文档/alias——防比较器与 kustomize 解释分歧）。
#
# 用法：verify-runner-topology.sh <base-dir> <head-dir>
# 退出码：0 = 合法 go-live topology PR；非 0 = 非法（fail-closed）。
set -euo pipefail

BASE_DIR="${1:?usage: verify-runner-topology.sh <base-dir> <head-dir>}"
HEAD_DIR="${2:?usage: verify-runner-topology.sh <base-dir> <head-dir>}"

LAUNCHER_IMAGE="docker.io/wontlost/aster-runner-launcher"
# 一个 topology PR 只允许改这三个源文件（其余 runner 目录文件必须与 base 逐字节相同，无新增/删除）。
# 授权迁移：kustomization.yaml（+resources）/ deployment.yaml（replicas 0→1）/ deploy-policy.yaml（删 launcher deferred）。
ALLOWED_CHANGED=("kustomization.yaml" "deployment.yaml" "deploy-policy.yaml")

die() { echo "::error::$*" >&2; exit 1; }
info() { echo ">> $*"; }

for c in yq jq kubectl python3; do command -v "$c" >/dev/null || die "${c} 未安装"; done
[[ -d "$BASE_DIR" ]] || die "base-dir 不存在：${BASE_DIR}"
[[ -d "$HEAD_DIR" ]] || die "head-dir 不存在：${HEAD_DIR}"

bf() { echo "$BASE_DIR/$1"; }
hf() { echo "$HEAD_DIR/$1"; }

# ── 严格 YAML 解析（拒重复键 + 恰 1 非空文档 + 无 alias）——防「比较器与 kustomize 解释分歧」──
# yq 对重复键 last-wins 静默通过（Codex 实证），故用 python pyyaml 的 duplicate-key 检测。
STRICT_PY="$(cat <<'PYEOF'
import sys, yaml
class Dup(yaml.SafeLoader): pass
def no_dup(loader, node, deep=False):
    seen = set()
    for k, _ in node.value:
        key = loader.construct_object(k, deep=deep)
        try:
            hkey = key if isinstance(key, (str, int, float, bool)) else repr(key)
        except Exception:
            hkey = repr(key)
        if hkey in seen:
            sys.stderr.write("DUPLICATE_KEY:%r\n" % (key,)); sys.exit(3)
        seen.add(hkey)
    return Dup.construct_mapping_original(loader, node, deep)
Dup.construct_mapping_original = Dup.construct_mapping
Dup.construct_mapping = no_dup
path = sys.argv[1]
src = open(path, 'r', encoding='utf-8').read()
# ★token 级 alias/anchor/merge 检测（非字符串启发式——Codex 抓：字符串扫描漏 [*a] flow-style +
#   误伤含 & 的字符串值）。用 PyYAML scanner 逐 token 判 Anchor/Alias。
try:
    for tok in yaml.scan(src, Loader=yaml.SafeLoader):
        if isinstance(tok, (yaml.tokens.AnchorToken, yaml.tokens.AliasToken)):
            sys.stderr.write("ALIAS_OR_ANCHOR\n"); sys.exit(4)
except yaml.YAMLError as e:
    sys.stderr.write("SCAN_ERR:%s\n" % e); sys.exit(6)
docs = [d for d in yaml.load_all(src, Loader=Dup) if d is not None]
# 允许 0 文档（注释-only 文件如 network-policy.yaml，kustomize 忽略未列入 resources 的它）；
# 拒 >1 文档（多文档夹带攻击）。
if len(docs) > 1:
    sys.stderr.write("MULTI_DOC:%d\n" % len(docs)); sys.exit(5)
PYEOF
)"
strict_parse() {  # $1=file — 拒重复键/多文档/alias，否则 die
  local f="$1" errf
  [[ -f "$f" ]] || die "文件缺失（无法严格解析）：${f}"
  errf="$(mktemp)" || die "mktemp 失败"
  if ! python3 -c "$STRICT_PY" "$f" 2>"$errf"; then
    local msg; msg="$(cat "$errf" 2>/dev/null)"; rm -f "$errf"
    die "YAML 严格解析失败（重复键/多文档/alias）：${f} —— ${msg}"
  fi
  rm -f "$errf"
}

canon() { yq -o=json 'sort_keys(..)' "$1" | jq -S '.'; }

assert_file_unchanged() {  # $1=relpath $2=desc
  local rel="$1" desc="$2" b h
  strict_parse "$(bf "$rel")"; strict_parse "$(hf "$rel")"
  b="$(canon "$(bf "$rel")")"; h="$(canon "$(hf "$rel")")"
  [[ "$b" == "$h" ]] || {
    echo "::error::topology PR 改动了 ${desc}（${rel}）——本 lane 禁止" >&2
    diff <(echo "$b") <(echo "$h") | head -40 >&2 || true
    die "${desc} 必须与 base 完全一致 → fail-closed"
  }
  info "${desc}（${rel}）base==head OK"
}

echo "=== [1/6] 目录文件集：只有 3 个授权文件可变，其余 base 文件逐字节不变，无新增/删除文件 ==="
# ★Codex 复审契约收紧：闭世界不止「渲染世界」，也须覆盖「目录内容」。否则攻击者可改注释-only 的
#   network-policy.yaml 或新增未引用的 backdoor.yaml（不进 resources、不影响渲染）→ canonical render
#   相等放行 → 恶意内容潜伏仓库待未来 PR 激活。故 topology PR 只允许改 {kustomization,deployment,
#   deploy-policy}.yaml 三个源文件，其余 runner 目录文件必须与 base 逐字节相同，且无文件新增/删除。
# 拒子目录（当前 base 全顶层；子目录文件会绕过文件集/复制模型）。
if find "$HEAD_DIR" -mindepth 1 -type d | read -r; then
  die "head runner 目录含子目录（禁止：当前拓扑全顶层，子目录会绕过文件集校验）"
fi
if find "$BASE_DIR" -mindepth 1 -type d | read -r; then
  die "base runner 目录含子目录（异常）"
fi
# 拒符号链接 + 非普通文件（防路径穿越/TOCTOU/设备文件）。
if find "$BASE_DIR" "$HEAD_DIR" -maxdepth 1 -mindepth 1 ! -type f | read -r; then
  die "runner 目录含非普通文件（符号链接/管道/设备等，禁止）"
fi
# ★文件集覆盖**所有**顶层条目（非仅 *.yaml——Codex 抓：非 YAML 文件如脚本/txt 会绕过 *.yaml 枚举）。
# 用 basename via sed（BSD/GNU 通用；find -printf 是 GNU-only 不可移植）。
base_files="$(find "$BASE_DIR" -maxdepth 1 -type f | sed 's#.*/##' | sort)"
head_files="$(find "$HEAD_DIR" -maxdepth 1 -type f | sed 's#.*/##' | sort)"
[[ "$base_files" == "$head_files" ]] || {
  echo "::error::topology PR 新增/删除了 runner 目录文件（禁止：只许改既有 3 授权文件；覆盖所有文件非仅 yaml）" >&2
  diff <(echo "$base_files") <(echo "$head_files") | head -20 >&2 || true
  die "目录文件集变更 → fail-closed"
}
# 逐文件比对：非授权文件必须 base==head（byte）；授权文件留待后续步骤按语义校验。
is_allowed() { local f="$1"; for a in "${ALLOWED_CHANGED[@]}"; do [[ "$f" == "$a" ]] && return 0; done; return 1; }
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if ! is_allowed "$f"; then
    if ! cmp -s "$(bf "$f")" "$(hf "$f")"; then
      die "topology PR 改动了非授权文件 ${f}（禁止：只许改 kustomization/deployment/deploy-policy）"
    fi
  fi
done <<<"$head_files"
info "目录文件集 OK（仅 3 授权文件可变，其余 byte-相同，无新增/删除/子目录/符号链接）"

echo "=== [2/6] image-lock.yaml + kustomization.images（pin 真相）base==head 精确不变 ==="
assert_file_unchanged "image-lock.yaml" "image-lock（验签真相）"
strict_parse "$(bf kustomization.yaml)"; strict_parse "$(hf kustomization.yaml)"
base_imgs="$(yq -o=json '.images // []' "$(bf kustomization.yaml)" | jq -S '.')"
head_imgs="$(yq -o=json '.images // []' "$(hf kustomization.yaml)" | jq -S '.')"
[[ "$base_imgs" == "$head_imgs" ]] || {
  echo "::error::topology PR 改动了 kustomization.images（pin transformer）——禁止" >&2
  diff <(echo "$base_imgs") <(echo "$head_imgs") | head -20 >&2 || true
  die "kustomization.images 必须与 base 完全一致 → fail-closed"
}
LAUNCHER_PINNED_DIGEST="$(jq -r --arg n "$LAUNCHER_IMAGE" '[.[] | select(.name == $n)] | if length == 1 then .[0].digest else "__ERR__" end' <<<"$base_imgs")"
[[ "$LAUNCHER_PINNED_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || die "base kustomization.images launcher 条数≠1 或 digest 形状非法：${LAUNCHER_PINNED_DIGEST}"
info "pin 真相不变 OK；launcher pinned digest=${LAUNCHER_PINNED_DIGEST}"

echo "=== [3/6] kustomization.yaml 除 resources delta 外整体 canonical 相等（堵所有 transformer/patches/generators 字段）==="
base_kust_norm="$(yq -o=json 'sort_keys(..) | .resources = "__NORM__"' "$(bf kustomization.yaml)" | jq -S '.')"
head_kust_norm="$(yq -o=json 'sort_keys(..) | .resources = "__NORM__"' "$(hf kustomization.yaml)" | jq -S '.')"
[[ "$base_kust_norm" == "$head_kust_norm" ]] || {
  echo "::error::kustomization.yaml 除 resources 外有其它变更（禁止 patches/replacements/transformers/generators/labels 等任何 transformer 字段）" >&2
  diff <(echo "$base_kust_norm") <(echo "$head_kust_norm") | head -30 >&2 || true
  die "kustomization 非 resources 变更 → fail-closed"
}
base_res="$(yq -o=json '.resources // []' "$(bf kustomization.yaml)" | jq -S '.')"
head_res="$(yq -o=json '.resources // []' "$(hf kustomization.yaml)" | jq -S '.')"
if jq -e 'any(.[]; test("://") or startswith("/") or test("\\.\\."))' <<<"$head_res" >/dev/null; then
  die "head resources 含远程 URL/绝对路径/.. （禁止：只许本地相对文件）"
fi
[[ "$(jq -r 'group_by(.) | map(select(length > 1)) | length' <<<"$head_res")" == "0" ]] \
  || die "head resources 含重复项（禁止）"
expected_res="$(jq -S '. + ["deployment.yaml","external-secrets.yaml"] | sort' <<<"$base_res")"
[[ "$expected_res" == "$(jq -S 'sort' <<<"$head_res")" ]] || {
  echo "::error::kustomization.resources delta 非法（须恰新增 deployment.yaml + external-secrets.yaml）" >&2
  diff <(echo "$expected_res") <(jq -S 'sort' <<<"$head_res") | head -20 >&2 || true
  die "resources delta → fail-closed"
}
info "kustomization 整体不变（仅 resources +deployment+external-secrets）OK"

echo "=== [4/6] deploy-policy.yaml 恰删 launcher deferred 一条（其余不变）==="
strict_parse "$(bf deploy-policy.yaml)"; strict_parse "$(hf deploy-policy.yaml)"
BASE_DP="$(bf deploy-policy.yaml)"; HEAD_DP="$(hf deploy-policy.yaml)"
[[ "$(yq "[.deferredImages[] | select(.image == \"$LAUNCHER_IMAGE\")] | length" "$BASE_DP")" == "1" ]] \
  || die "base deploy-policy launcher deferred 条数≠1"
[[ "$(yq "[.deferredImages[]? | select(.image == \"$LAUNCHER_IMAGE\")] | length" "$HEAD_DP")" == "0" ]] \
  || die "head deploy-policy 仍含 launcher deferred（go-live 须删该豁免，强制 render by-digest）"
base_dp_wo="$(yq -o=json "sort_keys(..) | .deferredImages = [.deferredImages[] | select(.image != \"$LAUNCHER_IMAGE\")]" "$BASE_DP" | jq -S '.')"
head_dp_wo="$(yq -o=json "sort_keys(..) | .deferredImages = [(.deferredImages // [])[] | select(.image != \"$LAUNCHER_IMAGE\")]" "$HEAD_DP" | jq -S '.')"
[[ "$base_dp_wo" == "$head_dp_wo" ]] || {
  echo "::error::deploy-policy 除删 launcher deferred 外有其它变更（禁止加泛化豁免/删全部/改 version）" >&2
  diff <(echo "$base_dp_wo") <(echo "$head_dp_wo") | head -20 >&2 || true
  die "deploy-policy delta → fail-closed"
}
info "deploy-policy 恰删 launcher deferred 一条 OK"

echo "=== [5/6] 闭世界 render 全等：head 渲染 == 「可信 base 源 + 授权 go-live 迁移」重建的期望渲染 ==="
# ★Codex 两轮红队后终极模型：不再字段黑名单/白名单。从**可信 base 源文件**重建一棵「期望 head 树」
#   ——base 全部文件原样（含 deployment.yaml/external-secrets.yaml，它们在 base dir 里已存在只是没进
#   resources），仅施加**三项授权 go-live 迁移**：kustomization.resources 加 deployment+external-secrets、
#   deployment replicas 0→1、deploy-policy 删 launcher deferred。渲染这棵期望树，要求 head 实际渲染与它
#   **逐字节 canonical 相等**。任何越权改动（role.yaml 提权 / deployment serviceAccountName·securityContext·
#   额外 env / external-secrets 额外 data / patches/transformer / 诱饵容器 / 夹带对象）都会使 head 渲染
#   偏离期望渲染 → fail-closed。这是唯一无死角的闭世界校验（渲染结果为准，非枚举字段）。
# 先严格解析两侧所有 yaml（拒重复键/多文档/alias，防解释分歧）。
for f in "$BASE_DIR"/*.yaml "$HEAD_DIR"/*.yaml; do strict_parse "$f"; done
# 从可信 base 重建期望 head 树。
EXP_DIR="$(mktemp -d)"
trap 'rm -rf "$EXP_DIR"' EXIT
cp "$BASE_DIR"/*.yaml "$EXP_DIR/" || die "重建期望树复制 base 失败"
yq -i '.resources += ["deployment.yaml", "external-secrets.yaml"]' "$EXP_DIR/kustomization.yaml" || die "期望树 resources 变换失败"
yq -i '.spec.replicas = 1' "$EXP_DIR/deployment.yaml" || die "期望树 replicas 变换失败"
yq -i ".deferredImages = [.deferredImages[] | select(.image != \"$LAUNCHER_IMAGE\")]" "$EXP_DIR/deploy-policy.yaml" || die "期望树 deploy-policy 变换失败"
exp_render="$(kubectl kustomize "$EXP_DIR" 2>/dev/null)" || die "期望树 render 失败（base 源本身有问题？）"
head_render="$(kubectl kustomize "$HEAD_DIR" 2>/dev/null)" || die "head 树 render 失败"
# canonical 归一（键序无关）后逐字节比对全渲染流。
canon_render() { yq -o=json 'sort_keys(..)' 2>/dev/null | jq -cS '.' | sort; }
exp_canon="$(echo "$exp_render" | canon_render)"
head_canon="$(echo "$head_render" | canon_render)"
[[ "$exp_canon" == "$head_canon" ]] || {
  echo "::error::head 渲染 != 「可信 base + 授权 go-live 迁移」期望渲染（禁止任何越权改动：既有对象篡改/提权/patches/transformer/诱饵/夹带对象/载体字段变更）" >&2
  diff <(echo "$exp_canon") <(echo "$head_canon") | head -40 >&2 || true
  die "闭世界 render 全等 → fail-closed"
}
# 纵深冗余：确认期望渲染确实含 launcher@base-pinned 且唯一（防「期望树本身被 base 污染」的极端情形；
#   base 是可信 checkout，此为额外自证）。
all_images="$(echo "$head_render" | yq -N '.. | select(has("image")) | .image' 2>/dev/null | awk 'NF && $0 != "null"' | sort -u)"
[[ "$all_images" == "${LAUNCHER_IMAGE}@${LAUNCHER_PINNED_DIGEST}" ]] \
  || die "head 渲染镜像集 != 唯一 {${LAUNCHER_IMAGE}@${LAUNCHER_PINNED_DIGEST}}（纵深自证失败）：${all_images}"
info "闭世界 render 全等 OK（head 渲染 == 可信 base + 三项授权 go-live 迁移）"

echo ""
info "✅ runner-topology go-live PR 全部不变量通过（pin 不变 + 闭世界 render 全等 = 仅激活已固定 launcher workload）"
