#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  echo "usage: $0 SOCKS_PORT" >&2
  exit 2
fi

PORT="$1"
HTTP_PORT=$((PORT + 1))
URL="${TEST_URL:-https://api.ipify.org?format=json}"

echo "SOCKS5 0.0.0.0:$PORT"
curl --max-time 20 --socks5-hostname "127.0.0.1:$PORT" "$URL"
echo

echo "HTTP 0.0.0.0:$HTTP_PORT"
curl --max-time 20 -x "http://127.0.0.1:$HTTP_PORT" "$URL"
echo
