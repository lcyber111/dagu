#!/usr/bin/env bash
# Contract smoke test + full create/access/idle-reclaim/restart/delete flow.
set -euo pipefail

# Root is derived from this script's location; GW_BASE comes from the runtime
# env file written by install.sh (.deploy-env) or the GW_BASE environment var.
ROOT="${DAGU_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GW_BASE="${GW_BASE:-}"
if [ -z "$GW_BASE" ] && [ -f "$ROOT/.deploy-env" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/.deploy-env"
  GW_BASE="${GATEWAY_PUBLIC_BASE_URL:-}"
fi
GW_BASE="${GW_BASE:-http://127.0.0.1:9088}"
DOCKER_NETWORK="${DOCKER_NETWORK:-dagu-net}"
UID_TEST="${UID_TEST:-usr_smoke01}"
COOKIE_JAR="/tmp/smoke-cookie.txt"

fail() { echo "FAIL: $1" >&2; exit 1; }
expect() { # $1 expected, $2 actual, $3 label
  [ "$1" = "$2" ] && echo "  ok   $3" || fail "$3 (expected $1, got $2)"
}

echo "== contract: GET /api/v1/health =="
HEALTH=""
for _ in $(seq 1 10); do
  HEALTH=$(curl -s --max-time 5 -w '\n%{http_code}' "$GW_BASE/api/v1/health" || true)
  [ "$(printf '%s' "$HEALTH" | tail -1)" = "200" ] && break
  sleep 2
done
expect 200 "$(printf '%s' "$HEALTH" | tail -1)" "health 200"
printf '%s' "$HEALTH" | head -1 | grep -q '"status":"healthy"' || fail "health body"

echo "== contract: webhook without token (expect 401) =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -d '{"uid":"x"}' "$GW_BASE/api/v1/webhooks/user_create")
expect 401 "$CODE" "no-token 401"

CREATE_TOKEN=$(cat "$ROOT/.webhook-tokens/user_create.token")
DELETE_TOKEN=$(cat "$ROOT/.webhook-tokens/user_delete.token")

echo "== contract: unknown webhook path (workerd returns 404) =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $CREATE_TOKEN" -H 'Content-Type: application/json' \
  -d '{}' "$GW_BASE/api/v1/webhooks/not_exist")
expect 404 "$CODE" "unknown path 404"

echo "== flow: create via gateway =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $CREATE_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"uid\":\"$UID_TEST\",\"username\":\"smoke\",\"resources\":{\"cpu_limit\":\"1\",\"memory_limit\":\"2Gi\"}}" \
  "$GW_BASE/api/v1/webhooks/user_create")
expect 200 "$CODE" "create trigger 200"

echo "== flow: wait ready =="
READY=no
for _ in $(seq 1 30); do
  IP=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$DOCKER_NETWORK\").IPAddress}}" "dagu-u-$UID_TEST" 2>/dev/null || true)
  if [ -n "$IP" ] && curl -s -o /dev/null --max-time 2 "http://$IP:4096/"; then
    READY=yes
    break
  fi
  sleep 3
done
expect yes "$READY" "container ready"

echo "== flow: tenant entry + cookie access =="
rm -f "$COOKIE_JAR"
curl -s -c "$COOKIE_JAR" -o /dev/null "$GW_BASE/portal/u/$UID_TEST"
CODE=$(curl -s -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' --max-time 15 "$GW_BASE/")
expect 200 "$CODE" "workspace page 200"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$GW_BASE/")
expect 404 "$CODE" "no-cookie 404"

echo "== flow: control plane went through workerd =="
WORKERD_LOG="${WORKERD_LOG:-$ROOT/logs/workerd-access.log}"
[ -f "$WORKERD_LOG" ] || fail "workerd log missing: $WORKERD_LOG"
grep -q "302 /portal/u/$UID_TEST" "$WORKERD_LOG" || fail "workerd did not handle /portal/u/$UID_TEST"
grep -q "webhook user_create" "$WORKERD_LOG" || fail "workerd did not forward user_create"
echo "  ok   control plane requests handled by workerd"

echo "== flow: idle reclaim -> starting page -> restart =="
# Negative check: a recently active container must NOT be reaped.
IDLE_TIMEOUT_MINUTES=5 bash "$ROOT/scripts/reap_idle.sh" >/dev/null
if docker inspect "dagu-u-$UID_TEST" >/dev/null 2>&1 && [ "$(docker inspect --format '{{.State.Running}}' "dagu-u-$UID_TEST")" != "true" ]; then
  fail "reaper stopped a recently active container"
fi
echo "  ok   reaper keeps recently active container"

# Simulate what reap_idle does when the timeout expires.
docker stop "dagu-u-$UID_TEST" >/dev/null
CODE=$(curl -s -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' --max-time 15 "$GW_BASE/")
expect 200 "$CODE" "starting page 200"
BODY=$(curl -s -b "$COOKIE_JAR" --max-time 15 "$GW_BASE/")
printf '%s' "$BODY" | grep -q "正在启动" || fail "starting page body"

# Trigger the restart the same way the starting page JS does.
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -b "$COOKIE_JAR" -H 'Content-Type: application/json' \
  -d "{\"payload\":{\"uid\":\"$UID_TEST\"}}" \
  "$GW_BASE/api/v1/restart/$UID_TEST")
expect 200 "$CODE" "restart trigger 200"

READY=no
for _ in $(seq 1 40); do
  IP=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$DOCKER_NETWORK\").IPAddress}}" "dagu-u-$UID_TEST" 2>/dev/null || true)
  if [ -n "$IP" ] && curl -s -o /dev/null --max-time 2 "http://$IP:4096/"; then
    READY=yes
    break
  fi
  sleep 3
done
expect yes "$READY" "container restarted and ready"
CODE=$(curl -s -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' --max-time 15 "$GW_BASE/")
expect 200 "$CODE" "workspace page 200 after restart"

echo "== flow: reap_idle stops idle container (short timeout) =="
IDLE_TIMEOUT_MINUTES=0 bash "$ROOT/scripts/reap_idle.sh" >/dev/null
sleep 2
if docker inspect "dagu-u-$UID_TEST" >/dev/null 2>&1 && [ "$(docker inspect --format '{{.State.Running}}' "dagu-u-$UID_TEST")" = "true" ]; then
  fail "container still running after reaper"
fi
echo "  ok   reaper stopped idle container"

echo "== flow: delete via gateway =="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $DELETE_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"uid\":\"$UID_TEST\",\"archive_data\":true}" \
  "$GW_BASE/api/v1/webhooks/user_delete")
expect 200 "$CODE" "delete trigger 200"
sleep 10
if docker inspect "dagu-u-$UID_TEST" >/dev/null 2>&1; then fail "container still exists"; fi
if [ -e "$ROOT/users/$UID_TEST" ]; then fail "user dir still exists"; fi
echo "  ok   resources reclaimed"

echo "ALL SMOKE TESTS PASSED"
