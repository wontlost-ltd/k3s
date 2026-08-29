#!/usr/bin/env bash
#
# Post-deploy smoke check (R31 incident closeout, 2026-05-29).
#
# Why this exists: a NetworkPolicy shipped at R31-6 broke production for
# ~90 minutes before anyone noticed. Audit-driven hardening was passing
# every manifest-level check but never probed the live ingress path.
# This script is the missing layer.
#
# What it does: hit each public HTTPS endpoint and assert
#   - status code is healthy (200 / 204 / 401 — anything but 502 / 503 / timeout)
#   - response carries the right Access-Control-Allow-Origin when an
#     allowlisted Origin is sent (catches CORS regressions early)
#
# Usage:
#   ./post-deploy-smoke.sh                # default targets, default origins
#   FAIL_FAST=true ./post-deploy-smoke.sh # exit on first failure
#   QUIET=true ./post-deploy-smoke.sh     # only print failures
#
# CI integration: chain after each ArgoCD sync, or run as a Kubernetes
# CronJob every 5 min and alert on non-zero exit. Either way, get this
# in front of a pager.

set -u
FAIL_FAST="${FAIL_FAST:-false}"
QUIET="${QUIET:-false}"

# method: GET (default) or HEAD (for streaming endpoints we just want
# the status line + headers, not the body).
TARGETS=(
  # name                      url                                                          expect-code  cors-origin                 method
  "policy-api lexicons        https://policy.aster-lang.dev/api/v1/lexicons                200          https://aster-lang.cloud    GET"
  "policy-api lexicons stream https://policy.aster-lang.dev/api/v1/lexicons/stream         200          https://aster-lang.cloud    HEAD"
  # ★ Probe every member of QUARKUS_HTTP_CORS_ORIGINS, not just one. The
  #   www.aster-lang.dev outage (2026-08-20) was a single missing allowlist entry
  #   that this script could not see, because it only ever sent one Origin.
  #   Keep this block in sync with apps/aster-lang/cloud/deployment.yaml.
  "policy-api cors www.cloud  https://policy.aster-lang.dev/api/v1/lexicons                200          https://www.aster-lang.cloud GET"
  "policy-api cors dev apex   https://policy.aster-lang.dev/api/v1/lexicons                200          https://aster-lang.dev      GET"
  "policy-api cors dev www    https://policy.aster-lang.dev/api/v1/lexicons                200          https://www.aster-lang.dev  GET"
  "policy-api health          https://policy.aster-lang.dev/q/health                       200          -                           GET"
  "cloud root                 https://aster-lang.cloud/                                    200          -                           GET"
  "marketing root             https://aster-lang.dev/                                      200          -                           GET"
  "lsp health                 https://lsp.aster-lang.dev/                                  404          -                           GET"
  # R32：ckeditor-builder serves Vaadin UI; root path should serve the SPA shell.
  # Probe via Spring Actuator health for deterministic 200.
  "ckeditor health            https://ckeditor-builder.wontlost.com/actuator/health        200          -                           GET"
)

pass=0
fail=0
fail_names=()

check() {
  local name="$1" url="$2" expect="$3" origin="$4" method="${5:-GET}"
  local curl_args=(-sS -o /dev/null -w "%{http_code}|%{header_json}" --max-time 8 -L -X "$method" "$url")
  if [ "$origin" != "-" ]; then
    curl_args=(-H "Origin: $origin" "${curl_args[@]}")
  fi
  local result
  if ! result=$(curl "${curl_args[@]}" 2>&1); then
    fail=$((fail + 1)); fail_names+=("$name (network: $result)")
    [ "$QUIET" != "true" ] && echo "FAIL  $name → curl failure: $result"
    [ "$FAIL_FAST" = "true" ] && exit 1
    return
  fi
  local code="${result%%|*}"
  local headers="${result#*|}"
  if [ "$code" != "$expect" ]; then
    fail=$((fail + 1)); fail_names+=("$name (got $code, expected $expect)")
    [ "$QUIET" != "true" ] && echo "FAIL  $name → got $code, expected $expect"
    [ "$FAIL_FAST" = "true" ] && exit 1
    return
  fi
  # CORS check (when origin specified)
  #
  # ★ Assert the *value*, not just presence. The header-exists-only check this
  #   replaced would PASS on a response echoing a different origin, or on a
  #   blanket "*" — i.e. exactly the regressions this script claims to catch.
  #   The 2026-08-20 www.aster-lang.dev incident was invisible here for both
  #   reasons: the origin was never probed, and even if it had been, any ACAO
  #   value would have satisfied the old check.
  #
  #   Quarkus echoes back the request Origin when it is allowlisted, so the
  #   contract is ACAO == the Origin we sent. "*" is treated as a failure: these
  #   are credentialed first-party endpoints and a wildcard is a real regression.
  if [ "$origin" != "-" ]; then
    # header_json values are arrays: {"access-control-allow-origin":["https://x"]}
    local acao
    acao=$(printf '%s' "$headers" \
      | tr -d ' ' \
      | grep -oi "\"access-control-allow-origin\":\[\"[^\"]*\"\]" \
      | head -1 \
      | sed -E 's/.*\[\"(.*)\"\]/\1/')
    if [ -z "$acao" ]; then
      fail=$((fail + 1)); fail_names+=("$name (missing ACAO header)")
      [ "$QUIET" != "true" ] && echo "FAIL  $name → ACAO header missing"
      [ "$FAIL_FAST" = "true" ] && exit 1
      return
    fi
    if [ "$acao" != "$origin" ]; then
      fail=$((fail + 1)); fail_names+=("$name (ACAO '$acao' != origin '$origin')")
      [ "$QUIET" != "true" ] && echo "FAIL  $name → ACAO '$acao', expected '$origin'"
      [ "$FAIL_FAST" = "true" ] && exit 1
      return
    fi
  fi
  pass=$((pass + 1))
  [ "$QUIET" != "true" ] && echo "PASS  $name → $code"
}

for line in "${TARGETS[@]}"; do
  # collapse multi-space → single, then split
  norm=$(printf '%s' "$line" | tr -s ' ')
  name=$(printf '%s\n' "$norm" | awk '{
    n=NF;
    printf "%s", $1;
    for (i = 2; i <= n - 4; i++) printf " %s", $i;
  }')
  url=$(printf '%s\n' "$norm" | awk '{print $(NF-3)}')
  expect=$(printf '%s\n' "$norm" | awk '{print $(NF-2)}')
  origin=$(printf '%s\n' "$norm" | awk '{print $(NF-1)}')
  method=$(printf '%s\n' "$norm" | awk '{print $NF}')
  check "$name" "$url" "$expect" "$origin" "$method"
done

echo
echo "Smoke result: $pass pass / $((pass + fail)) total ($fail failed)"
if [ "$fail" -gt 0 ]; then
  echo "Failures:"
  for f in "${fail_names[@]}"; do echo "  - $f"; done
  exit 1
fi
