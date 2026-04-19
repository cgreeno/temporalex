#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_CORE_DIR="${SDK_CORE_DIR:-$(cd "$ROOT_DIR/.." && pwd)/../temporalio/sdk-core}"
OUT_DIR="$ROOT_DIR/lib/temporalex/proto"

if ! command -v protoc >/dev/null 2>&1; then
  echo "protoc is required" >&2
  exit 1
fi

if ! command -v protoc-gen-elixir >/dev/null 2>&1; then
  echo "protoc-gen-elixir is required; install it with mix escript.install hex protobuf" >&2
  exit 1
fi

API_PROTO_DIR="$SDK_CORE_DIR/crates/common/protos/api_upstream"
LOCAL_PROTO_DIR="$SDK_CORE_DIR/crates/common/protos/local"
COMMON_PROTO_DIR="$SDK_CORE_DIR/crates/common/protos"

if [[ ! -d "$API_PROTO_DIR" || ! -d "$LOCAL_PROTO_DIR" ]]; then
  echo "SDK_CORE_DIR must point at a temporalio/sdk-core checkout: $SDK_CORE_DIR" >&2
  exit 1
fi

mapfile -t proto_files < <(
  {
    find "$API_PROTO_DIR/temporal/api" -type f -name "*.proto" ! -name "service.proto"
    find "$LOCAL_PROTO_DIR/temporal/sdk/core" -type f -name "*.proto"
  } | sort
)

rm -rf "$OUT_DIR/temporal/api" "$OUT_DIR/temporal/sdk/core"
mkdir -p "$OUT_DIR"

protoc \
  --elixir_out="$OUT_DIR" \
  -I "$API_PROTO_DIR" \
  -I "$LOCAL_PROTO_DIR" \
  -I "$COMMON_PROTO_DIR" \
  -I "$ROOT_DIR/deps/protobuf/src" \
  "${proto_files[@]}"

echo "Generated ${#proto_files[@]} protobuf files into $OUT_DIR"
