#!/usr/bin/env bash

# 从 image-pin PR 描述提取源仓与本次源提交信息。
parse_image_pin_pr_body() {
  local body="$1" image source_sha run_id source_repo
  image="$(sed -n 's/^image: //p' <<<"$body" | head -1)"
  source_sha="$(sed -n 's/^sourceSha: //p' <<<"$body" | head -1)"
  run_id="$(sed -n 's/^runId: //p' <<<"$body" | head -1)"
  case "$image" in
    docker.io/wontlost/aster-api) source_repo="wontlost-ltd/aster-api" ;;
    docker.io/wontlost/aster-cloud-migrate|docker.io/wontlost/aster-lsp) source_repo="wontlost-ltd/aster-cloud" ;;
    *) return 1 ;;
  esac
  [[ "$source_sha" =~ ^[0-9a-fA-F]{7,64}$ && "$run_id" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n%s\n%s\n' "$source_repo" "$source_sha" "$run_id"
}
