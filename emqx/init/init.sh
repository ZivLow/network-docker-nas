#!/bin/sh
# One-shot seeder: creates SCRAM (MQTT5 enhanced-auth) users via the EMQX REST
# API. Password-based (v3/v3.1.1) users are seeded by EMQX itself from
# etc/auth-built-in-db-bootstrap.csv, so they are NOT handled here.
#
# SCRAM user definitions live in /init/scram-users.csv (header + rows):
#   user_id,password,is_superuser
#   scram-dev,change_me_scrm_1,false
#
# Idempotent: runs on every `up`; the API returns 409 (already exists) for
# existing users, which is treated as success. Admin login falls back to the
# stock "public" password when EMQX_DASHBOARD__DEFAULT_PASSWORD doesn't apply
# (it only takes effect on a data-dir first boot).
# Deterministic authenticator id: "<mechanism>:<backend>" per EMQX 5.x/6.x.
set -eu

API="http://emqx:18083/api/v5"
CSV="/init/scram-users.csv"
SID="scram:built_in_database"

[ -f "$CSV" ] || { echo "[init] no $CSV, nothing to seed"; exit 0; }

echo "[init] waiting for API..."
i=0
until curl -sf "$API/status" >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 60 ] && { echo "[init] API never came up"; exit 1; }
  sleep 2
done

echo "[init] login"
TOKEN=""
for PW in "$ADMIN_PASSWORD" "public"; do
  TOKEN=$(curl -sf -X POST "$API/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"admin\",\"password\":\"$PW\"}" \
    | grep -o '"token":"[^"]*"' | head -n1 | cut -d'"' -f4) || true
  [ -n "$TOKEN" ] && break
done
[ -n "$TOKEN" ] || { echo "[init] login failed"; exit 1; }
AUTH="Authorization: Bearer $TOKEN"

FAILED=0
while IFS=, read -r uid pass su; do
  # skip header + blank lines + CRLF leftovers
  [ "${uid:-}" = "user_id" ] && continue
  uid=$(printf '%s' "$uid" | tr -d '\r')
  [ -n "$uid" ] || continue
  pass=$(printf '%s' "${pass:-}" | tr -d '\r')
  su=$(printf '%s' "${su:-false}" | tr -d '\r ')
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/authentication/$SID/users" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"user_id\":\"$uid\",\"password\":\"$pass\",\"is_superuser\":$su}")
  case "$code" in
    2*)  echo "[init] scram user $uid created" ;;
    409) echo "[init] scram user $uid already exists (ok)" ;;
    *)   echo "[init] scram user $uid FAILED http=$code"; FAILED=1 ;;
  esac
done < "$CSV"

[ "$FAILED" -eq 0 ] || { echo "[init] completed with failures"; exit 1; }
echo "[init] done"