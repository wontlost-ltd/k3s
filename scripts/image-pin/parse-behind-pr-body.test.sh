#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/parse-behind-pr-body.sh"

body=$'自动开启。\n\nimage: docker.io/wontlost/aster-cloud-migrate\ndigest: sha256:abc\nsourceSha: 0123456789abcdef0123456789abcdef01234567\nrunId: 12345\n'
expected=$'wontlost-ltd/aster-cloud\n0123456789abcdef0123456789abcdef01234567\n12345'
actual="$(parse_image_pin_pr_body "$body")"
[[ "$actual" == "$expected" ]]

api_body=$'image: docker.io/wontlost/aster-api\nsourceSha: abcdef0123456789abcdef0123456789abcdef01\nrunId: 9876'
[[ "$(parse_image_pin_pr_body "$api_body")" == $'wontlost-ltd/aster-api\nabcdef0123456789abcdef0123456789abcdef01\n9876' ]]

lsp_body=$'image: docker.io/wontlost/aster-lsp\nsourceSha: abcdef0123456789abcdef0123456789abcdef01\nrunId: 9876'
[[ "$(parse_image_pin_pr_body "$lsp_body")" == $'wontlost-ltd/aster-cloud\nabcdef0123456789abcdef0123456789abcdef01\n9876' ]]

invalid=$'image: docker.io/unknown/image\nsourceSha: 0123456789abcdef0123456789abcdef01234567\nrunId: 12345'
if parse_image_pin_pr_body "$invalid" >/dev/null; then
  echo '未知镜像映射应被拒绝' >&2
  exit 1
fi
echo 'image-pin PR body 解析自测通过'
