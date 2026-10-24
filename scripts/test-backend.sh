#!/bin/bash
# Backend smoke suite for ClipLink.
# Usage: scripts/test-backend.sh [BASE_URL]   (default http://127.0.0.1:8787)
# Prereqs: `npx wrangler dev --port 8787 --ip 127.0.0.1 --test-scheduled` running
#          and schema applied (`npx wrangler d1 execute cliplink --local --file=schema.sql`).
set -u

BASE="${1:-http://127.0.0.1:8787}"
PASS=0; FAIL=0
SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
TAG="$(date +%s)_$$"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check() { # check NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1 ($3)";
  else FAIL=$((FAIL+1)); echo "  FAIL $1 (expected $2, got $3)"; fi
}

echo "== health / limits =="
check "healthz 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/healthz")"
curl -s "$BASE/api/v1/limits" -o "$TMP/limits.json"
check "limits json has maxFileBytes" "yes" "$(grep -q maxFileBytes "$TMP/limits.json" && echo yes)"

echo "== upload roundtrip =="
head -c 40000 /dev/urandom > "$TMP/file.bin"
RESP=$(curl -s -X POST "$BASE/api/v1/shares" \
  -H "Content-Type: application/octet-stream" \
  -H "X-ClipLink-Filename: readme-$TAG Bin File.bin" \
  --data-binary @"$TMP/file.bin")
TOKEN=$(echo "$RESP" | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
REVOKE=$(echo "$RESP" | sed -n 's/.*"revokeToken" *: *"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] && TOKEN_OK=yes || TOKEN_OK=no
check "upload returns token" "yes" "$TOKEN_OK"

curl -s "$BASE/api/v1/shares/$TOKEN/download" -o "$TMP/dl.bin"
check "download byte-identical" "yes" "$(cmp -s "$TMP/dl.bin" "$TMP/file.bin" && echo yes)"

SIZE_OK=$(curl -s "$BASE/api/v1/shares/$TOKEN" | grep -o '"size" *: *40000')
check "metadata size matches" "yes" "$([ -n "$SIZE_OK" ] && echo yes || echo no)"
check "share page 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/s/$TOKEN")"
check "attachment disposition" "yes" "$(curl -s -D - -o /dev/null "$BASE/api/v1/shares/$TOKEN/download" | grep -i 'Content-Disposition' | grep -i attachment >/dev/null 2>&1 && echo yes || echo no)"

echo "== error paths =="
check "unknown token 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/shares/zzzzzzzzzzz/download")"
check "empty file 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/v1/shares" -H 'Content-Type: application/octet-stream' -H 'X-ClipLink-Filename: empty.bin' --data-binary '')"

MAX=$(echo "$RESP" >/dev/null; curl -s "$BASE/api/v1/limits" | sed -n 's/.*"maxFileBytes" *: *\([0-9]*\).*/\1/p')
head -c $((MAX + 10)) /dev/urandom > "$TMP/big.bin"
check "oversize 413" "413" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/v1/shares" -H 'Content-Type: application/octet-stream' -H "X-ClipLink-Filename: big.bin" --data-binary @"$TMP/big.bin")"

echo "== revocation =="
check "revoke without token 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$BASE/api/v1/shares/$TOKEN")"
check "revoke with token 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "X-ClipLink-Revoke-Token: $REVOKE" "$BASE/api/v1/shares/$TOKEN")"
check "download after revoke 410" "410" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/shares/$TOKEN/download")"
REVOKED_PAGE=$(curl -s "$BASE/s/$TOKEN")
check "share page says revoked" "yes" "$(echo "$REVOKED_PAGE" | grep -qi 'revoked' && echo yes)"

echo "== storage budget (advertised only; 507/eviction paths are exercised in the tiny env) =="
curl -s "$BASE/api/v1/limits" | grep -o '"storageBudgetBytes"' >/dev/null && echo "  ok   storageBudgetBytes advertised"

echo "== expiration (uses current clock margin; authoritative tiny-env check lives in e2e notes) =="
echo "  (set EXPIRY_MINUTES=0.2 in [env.tiny] and run against port 8788 for the 12s expiry path)"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = "0" ]
