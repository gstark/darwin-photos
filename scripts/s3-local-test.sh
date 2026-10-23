#!/bin/bash
# Runs the S3 integration tests against a temporary local MinIO server.
#   scripts/s3-local-test.sh
# Needs `minio` (brew install minio). No Full Disk Access is needed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DATA=$(/usr/bin/mktemp -d -t shoebox-minio)
PORT=${MINIO_PORT:-9123}

export MINIO_ROOT_USER=shoebox
export MINIO_ROOT_PASSWORD=shoebox-test
minio server "$DATA" --address "127.0.0.1:$PORT" --console-address "127.0.0.1:$((PORT + 1))" > "$DATA.log" 2>&1 &
SERVER=$!
trap '/bin/kill $SERVER 2>/dev/null; /bin/rm -rf "$DATA" "$DATA.log"' EXIT

for _ in $(/usr/bin/seq 50); do
  /usr/bin/curl -sf "http://127.0.0.1:$PORT/minio/health/live" > /dev/null && break
  /bin/sleep 0.2
done

cd "$ROOT"
AWS_ACCESS_KEY_ID=$MINIO_ROOT_USER \
AWS_SECRET_ACCESS_KEY=$MINIO_ROOT_PASSWORD \
AWS_PROFILE= \
SHOEBOX_S3_TEST_ENDPOINT="http://127.0.0.1:$PORT" \
  swift test --filter ShoeboxS3Tests
