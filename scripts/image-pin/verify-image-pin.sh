#!/usr/bin/env bash
# verify-image-pin —— image-lock 验签核心逻辑（可脱离 GitHub Actions 单测）
#
# 统一镜像 digest pin 设计 v2（A′）Phase 1 —— wontlost-ltd/k3s#4。
# blocker1 spike：cosign verify + --certificate-github-workflow-sha + freshness 不变式。
# blocker2 spike：信任根 = allowed-images.yaml（非 PR 内容），fail-closed。
#
# ★ Codex 对抗式审查修正（72→）：
#   - 只验证**本 PR 改动的** entry（base vs head diff），否则单镜像发布被其它 entry 的
#     freshness 卡死（多 entry 死锁）。未改 entry 视为既有 bootstrap 状态，跳过。
#   - policy 查表用 `jq --arg`（数据面）而非把 PR 字符串拼进 yq 表达式（防表达式注入）。
#   - 对 allowed-images 字段 + image-lock 的 image 做形状/字符集 fail-closed 校验。
#
# 用法：
#   verify-image-pin.sh <allowed-images.yaml> <base-lock.yaml> <head-lock.yaml> [head-kustomization.yaml]
#     base-lock = PR base 分支（可信 main）的 image-lock；head-lock = PR head 的 image-lock。
#     只对 head 中 digest/sourceSha 相对 base 发生变化（或 base 中不存在）的 image 做全量验签。
#     head-kustomization（可选，Phase 3 keystone）= PR head 的 kustomization.yaml：
#       提供则对每个变更 entry 校验 kustomization images[].digest == image-lock digest（部署真相
#       与验签真相一致）。渲染层校验（kubectl kustomize 出 @sha256）由 workflow 做。
# 依赖：cosign(>=v3.1.1)、yq、gh（freshness 查源仓 HEAD，需 GH_TOKEN 只读）、jq。
# 环境变量：
#   IMAGE_PIN_FRESHNESS=latest-only|off   默认 latest-only（Phase 1 决策）
#     off 仅用于本地单测/Phase 2 接通前；生产必须 latest-only。
#
# 退出码：0 全过（含"无变更 entry"）；非 0 = fail-closed。
set -euo pipefail

USAGE="usage: verify-image-pin.sh <allowed> <base-lock> <head-lock> [head-kustomization] [base-kustomization] [head-deployment] [base-deployment]"
ALLOWED="${1:?$USAGE}"
BASE_LOCK="${2:?$USAGE}"
HEAD_LOCK="${3:?$USAGE}"
HEAD_KUSTOMIZATION="${4:-}"
BASE_KUSTOMIZATION="${5:-}"
# ★env-binding（deployBinding: env）的部署真相载体（runner Deployment）：head/base 两侧。
#   仅 env-bound 镜像用；kustomization-bound 镜像忽略这两参数（走上面的 kustomization 路径）。
HEAD_DEPLOYMENT="${6:-}"
BASE_DEPLOYMENT="${7:-}"
FRESHNESS="${IMAGE_PIN_FRESHNESS:-latest-only}"

# ★★verifier 硬编码 base 侧 selector（用户决策②：绝不信 PR/workflow 供的 selector，防恶意 selector
#   指向别处绕验）。env-bound 镜像的部署真相恒为 runner Deployment 的 RUNNER_IMAGE_DIGEST env value。
ENV_BIND_SELECTOR='.spec.template.spec.containers[0].env[] | select(.name == "RUNNER_IMAGE_DIGEST") | .value'

die() { echo "::error::$*" >&2; exit 1; }
info() { echo ">> $*"; }

command -v cosign >/dev/null || die "cosign 未安装（需 >=v3.1.1）"
command -v yq >/dev/null || die "yq 未安装"
command -v jq >/dev/null || die "jq 未安装"
[[ -f "$ALLOWED" ]] || die "找不到 allowed-images 白名单：$ALLOWED"
[[ -f "$HEAD_LOCK" ]] || die "找不到 head image-lock：$HEAD_LOCK"
# base-lock 允许不存在（首次引入 image-lock 的 PR）：视为空 base。
[[ -f "$BASE_LOCK" ]] || { info "base-lock 不存在，视为空（首次引入）"; BASE_LOCK=/dev/null; }

# 全部转 JSON 一次（数据面处理，杜绝把 PR 值拼进 yq/jq 表达式）。
# ★ 强制数值型标量转字符串：否则全数字的 sourceSha（合法 git SHA 可全为十进制数字）
#   会被 yq 当 int/float 解析而精度损坏（如 111…1 → 1.11…e+39）。见 Codex 审查后测出。
to_str='(.. | select(tag == "!!int" or tag == "!!float")) |= tostring'
allowed_json="$(yq -o=json "$to_str" "$ALLOWED")"
head_json="$(yq -o=json "$to_str" "$HEAD_LOCK")"
base_json="$(yq -o=json "$to_str" "$BASE_LOCK" 2>/dev/null || echo '{"images":[]}')"
[[ "$(jq -r '.images // "null"' <<<"$base_json")" != "null" ]] || base_json='{"images":[]}'

# Phase 3 keystone：加载 head kustomization（若提供）用于 digest 一致性校验。
kust_json='{"images":[]}'
if [[ -n "$HEAD_KUSTOMIZATION" ]]; then
  [[ -f "$HEAD_KUSTOMIZATION" ]] || die "找不到 head kustomization：$HEAD_KUSTOMIZATION"
  kust_json="$(yq -o=json "$to_str" "$HEAD_KUSTOMIZATION")"

  # ★ Codex 审查 Critical#2/#3：kustomization **语义 diff allowlist**。
  # push ruleset 放开了 kustomization 整文件 → 必须在此证明 image-pin PR **只改了**
  # images[].digest，其它字段（resources/patches/generators/namespace/images[].name…）
  # 与 base 完全相同。否则攻击者可借 image-pin PR 改部署语义而 verify 放行。
  # 实现：把两侧 kustomization 的**所有** images[].digest 归一化为占位后，要求全文 JSON 相等。
  # ★ 语义 diff 用**原生** yq→json（不做 to_str），保持类型级严格比较（1 vs "1" 视为不等）——
  #   Codex 复审建议：kustomization 无数值型 SHA 问题，类型级更严。
  if [[ -n "$BASE_KUSTOMIZATION" ]]; then
    [[ -f "$BASE_KUSTOMIZATION" ]] || die "找不到 base kustomization：$BASE_KUSTOMIZATION"
    base_kust_raw="$(yq -o=json '.' "$BASE_KUSTOMIZATION")"
    head_kust_raw="$(yq -o=json '.' "$HEAD_KUSTOMIZATION")"
    norm='(.images[]?.digest) = "__NORM__"'
    base_norm="$(jq -S "$norm" <<<"$base_kust_raw")"
    head_norm="$(jq -S "$norm" <<<"$head_kust_raw")"
    if [[ "$base_norm" != "$head_norm" ]]; then
      echo "::error::kustomization 除 images[].digest 外有其它变更（禁止：image-pin PR 只能改 digest，不得改 resources/patches/namespace 等部署语义）"
      diff <(echo "$base_norm") <(echo "$head_norm") | head -40 >&2 || true
      die "kustomization semantic-diff 校验失败 → fail-closed"
    fi
    info "kustomization semantic-diff OK（仅 images[].digest 变更）"
  else
    # 无 base kustomization 传入：无法做语义 diff。生产必须传（workflow 会传）；此处 fail-closed。
    [[ "$FRESHNESS" == "off" ]] \
      || die "提供了 head-kustomization 但缺 base-kustomization → 无法做 semantic-diff（生产必须两侧都传）"
    info "  （freshness=off 单测：跳过 kustomization semantic-diff）"
  fi
fi

OIDC_ISSUER="$(jq -r '.oidcIssuer // "null"' <<<"$allowed_json")"
[[ -n "$OIDC_ISSUER" && "$OIDC_ISSUER" != "null" ]] || die "allowed-images 缺 oidcIssuer"

head_count="$(jq -r '.images | length' <<<"$head_json")"
[[ "$head_count" -gt 0 ]] || die "head image-lock 为空，无 entry"

fail=0
changed=0
for i in $(seq 0 $((head_count - 1))); do
  entry="$(jq -c ".images[$i]" <<<"$head_json")"
  image="$(jq -r '.image' <<<"$entry")"
  digest="$(jq -r '.digest' <<<"$entry")"
  source_sha="$(jq -r '.sourceSha' <<<"$entry")"

  # ── 只验证**变化的** entry：head 的 (digest,sourceSha) 与 base 同名 image 一致则跳过 ──
  base_entry="$(jq -c --arg img "$image" '.images[]? | select(.image == $img)' <<<"$base_json")"
  if [[ -n "$base_entry" ]]; then
    base_digest="$(jq -r '.digest' <<<"$base_entry")"
    base_sha="$(jq -r '.sourceSha' <<<"$base_entry")"
    # ★ Codex 复审建议：runId-only 变更（digest/sourceSha 不变）应拒绝——保护 audit 元数据
    #   完整性，防止在不重新验签的情况下改 provenance runId。
    base_run="$(jq -r '.runId // ""' <<<"$base_entry")"
    head_run="$(jq -r '.runId // ""' <<<"$entry")"
    if [[ "$base_digest" == "$digest" && "$base_sha" == "$source_sha" ]]; then
      [[ "$base_run" == "$head_run" ]] \
        || die "entry[$i] ${image} 只改了 runId 而 digest/sourceSha 未变（禁止：runId 变更须伴随重新验签的 digest/sourceSha）"
      info "entry[$i] $image 未变更，跳过（既有 bootstrap 状态）"
      continue
    fi
  fi
  changed=$((changed + 1))
  info "entry[$i] 变更: $image@$digest (sourceSha=$source_sha)"

  # ── image 字符集 fail-closed（受控 registry/repo，防怪值进 cosign/表达式）──
  [[ "$image" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ ]] \
    || { echo "::error::entry[$i] image 字符集非法：$image"; fail=1; continue; }

  # ── 规则 1：image 必须在可信白名单内（jq --arg 数据面查表，非表达式插值）──
  policy="$(jq -c --arg img "$image" '.images[] | select(.image == $img)' <<<"$allowed_json")"
  [[ -n "$policy" ]] || { echo "::error::entry[$i] image 不在 allowed-images 白名单：$image"; fail=1; continue; }

  source_repo="$(jq -r '.sourceRepo' <<<"$policy")"
  workflow_file="$(jq -r '.workflowFile' <<<"$policy")"
  source_ref="$(jq -r '.sourceRef' <<<"$policy")"

  # ── allowed-images 字段形状 fail-closed（即便人工误改也不把怪值送进 gh api / cosign）──
  [[ "$source_repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || { echo "::error::entry[$i] allowed-images sourceRepo 形状非法：$source_repo"; fail=1; continue; }
  [[ "$workflow_file" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] \
    || { echo "::error::entry[$i] allowed-images workflowFile 形状非法：$workflow_file"; fail=1; continue; }
  [[ "$source_ref" =~ ^refs/heads/[A-Za-z0-9._/-]+$ && "$source_ref" != *".."* ]] \
    || { echo "::error::entry[$i] allowed-images sourceRef 形状非法：$source_ref"; fail=1; continue; }

  # ── image-lock 值形状（digest sha256、sourceSha 40hex，拒种子/占位混入生产）──
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::entry[$i] digest 形状非法：$digest"; fail=1; continue; }
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::entry[$i] sourceSha 非 40-hex（种子/占位不得进生产）：$source_sha"; fail=1; continue; }

  # ── 部署真相一致性（binding-mode 分流）──
  # 每个 image 的部署真相载体由 allowed-images 的 deployBinding 决定（可信 base 侧单源，非 PR head）：
  #   kustomization（默认）：kustomization.images[].digest == image-lock digest（静态部署镜像）。
  #   env：runner Deployment 的 RUNNER_IMAGE_DIGEST env value == image-lock digest（launcher 运行时注入）。
  binding="$(jq -r --arg img "$image" '.images[] | select(.image == $img) | .deployBinding // "kustomization"' <<<"$allowed_json")"
  [[ "$binding" == "kustomization" || "$binding" == "env" ]] \
    || { echo "::error::entry[$i] allowed-images deployBinding 非法值：$binding（须 kustomization|env）"; fail=1; continue; }

  if [[ "$binding" == "kustomization" ]]; then
    # ── Phase 3 keystone：kustomization digest 一致性（部署真相 == 验签真相）──
    # 提供了 head kustomization 时：本镜像在 kustomization.images 里必须存在且 digest 与 image-lock
    # 相等。否则"验签通过的 digest"与"实际部署的 digest"可能不一致 → 打穿 by-digest 保证。
    if [[ -n "$HEAD_KUSTOMIZATION" ]]; then
      kust_digest="$(jq -r --arg img "$image" '.images[]? | select(.name == $img) | .digest // empty' <<<"$kust_json")"
      [[ -n "$kust_digest" ]] \
        || { echo "::error::entry[$i] ${image} 在 kustomization.images 中缺失（部署不会 by-digest 该镜像）"; fail=1; continue; }
      [[ "$kust_digest" == "$digest" ]] \
        || { echo "::error::entry[$i] kustomization digest(${kust_digest}) != image-lock digest(${digest})（部署真相与验签真相不一致）"; fail=1; continue; }
      info "  kustomization 一致性 OK（deploy digest == verified digest）"
    fi
  else
    # ── env-binding：runner Deployment 的 RUNNER_IMAGE_DIGEST env value == image-lock digest ──
    # ★用 base 侧硬编码 ENV_BIND_SELECTOR（不信 PR 供的 selector），读 head deployment 的 env value，
    #   断言 == 本次将 cosign-验签的 image-lock digest（env value 即部署真相；launcher 用它构 runner 引用）。
    [[ -n "$HEAD_DEPLOYMENT" ]] \
      || { echo "::error::entry[$i] ${image} 是 env-bound 但未提供 head-deployment（无法校验 RUNNER_IMAGE_DIGEST env value）"; fail=1; continue; }
    [[ -f "$HEAD_DEPLOYMENT" ]] \
      || { echo "::error::entry[$i] head-deployment 不存在：$HEAD_DEPLOYMENT"; fail=1; continue; }
    env_value="$(yq "$ENV_BIND_SELECTOR" "$HEAD_DEPLOYMENT" 2>/dev/null || true)"
    [[ -n "$env_value" && "$env_value" != "null" ]] \
      || { echo "::error::entry[$i] head-deployment 中 RUNNER_IMAGE_DIGEST env 缺失/为空（selector=硬编码 base 侧）"; fail=1; continue; }
    [[ "$env_value" == "$digest" ]] \
      || { echo "::error::entry[$i] RUNNER_IMAGE_DIGEST env value(${env_value}) != image-lock digest(${digest})（部署真相与验签真相不一致）"; fail=1; continue; }
    info "  env-binding 一致性 OK（RUNNER_IMAGE_DIGEST env == verified digest）"

    # ── deployment semantic-diff allowlist（类比 kustomization :70-88）──
    # push ruleset 放开了 runner/deployment.yaml 整文件 → 必须证明 image-pin PR **只改了** 该
    #   RUNNER_IMAGE_DIGEST env value，其它字段（replicas/securityContext/其它 env/probe…）与 base
    #   完全相同。否则攻击者可借 image-pin PR 改部署语义（如 replicas 0→N、放松 securityContext）而 verify 放行。
    # 实现：把两侧 deployment 的该 env value 归一化为占位后，要求全文 JSON 相等（原生 yq→json，类型级严格）。
    [[ -n "$BASE_DEPLOYMENT" ]] \
      || { [[ "$FRESHNESS" == "off" ]] || { echo "::error::entry[$i] env-bound 提供了 head-deployment 但缺 base-deployment → 无法做 semantic-diff（生产必须两侧都传）"; fail=1; continue; }; info "  （freshness=off 单测：跳过 deployment semantic-diff）"; }
    if [[ -n "$BASE_DEPLOYMENT" ]]; then
      [[ -f "$BASE_DEPLOYMENT" ]] || { echo "::error::entry[$i] base-deployment 不存在：$BASE_DEPLOYMENT"; fail=1; continue; }
      env_norm='(.spec.template.spec.containers[0].env[] | select(.name == "RUNNER_IMAGE_DIGEST")).value = "__NORM__"'
      base_dep_norm="$(yq -o=json "$env_norm" "$BASE_DEPLOYMENT" | jq -S '.')"
      head_dep_norm="$(yq -o=json "$env_norm" "$HEAD_DEPLOYMENT" | jq -S '.')"
      if [[ "$base_dep_norm" != "$head_dep_norm" ]]; then
        echo "::error::entry[$i] deployment 除 RUNNER_IMAGE_DIGEST env value 外有其它变更（禁止：image-pin PR 只能改该 env value，不得改 replicas/securityContext/其它 env 等部署语义）"
        diff <(echo "$base_dep_norm") <(echo "$head_dep_norm") | head -40 >&2 || true
        echo "::error::entry[$i] deployment semantic-diff 校验失败 → fail-closed"; fail=1; continue
      fi
      info "  deployment semantic-diff OK（仅 RUNNER_IMAGE_DIGEST env value 变更）"
    fi
  fi

  cert_identity="https://github.com/${source_repo}/.github/workflows/${workflow_file}@${source_ref}"

  # ── 规则 2：cosign 验签（绑定源仓 workflow 身份 + 源 SHA）—— blocker1 ──
  if cosign verify \
        --certificate-oidc-issuer "$OIDC_ISSUER" \
        --certificate-identity "$cert_identity" \
        --certificate-github-workflow-repository "$source_repo" \
        --certificate-github-workflow-ref "$source_ref" \
        --certificate-github-workflow-sha "$source_sha" \
        "${image}@${digest}" >/dev/null 2>&1; then
    info "  cosign verify OK (身份=${cert_identity}, sha=${source_sha})"
  else
    echo "::error::entry[$i] cosign verify 失败：${image}@${digest} 身份=${cert_identity} sha=${source_sha}"
    fail=1; continue
  fi

  # ── 规则 3：freshness（latest-only）—— sourceSha == 源仓 sourceRef 当前 HEAD ──
  # ★ current HEAD 从可信 GitHub API 取，绝不从 image-lock/PR 取（blocker1 E）。
  if [[ "$FRESHNESS" == "latest-only" ]]; then
    command -v gh >/dev/null || die "freshness=latest-only 需要 gh"
    branch="${source_ref#refs/heads/}"
    current_head="$(gh api "repos/${source_repo}/git/ref/heads/${branch}" --jq '.object.sha' 2>/dev/null)" \
      || { echo "::error::entry[$i] 取 ${source_repo}@${branch} 当前 HEAD 失败"; fail=1; continue; }
    if [[ "$current_head" == "$source_sha" ]]; then
      info "  freshness OK (HEAD=${current_head})"
    else
      echo "::error::entry[$i] freshness 失败: sourceSha=${source_sha} != 源仓当前 HEAD=${current_head} (stale 或 rollback, 禁 auto-merge)"
      fail=1; continue
    fi
  else
    info "  freshness=off（仅限本地单测/Phase 2 接通前，生产禁用）"
  fi
done

[[ "$fail" -eq 0 ]] || die "image-pin 验签未全过 → fail-closed"
info "image-pin 验签通过（变更 entry 数=${changed}）"
