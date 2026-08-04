#!/usr/bin/env bash
set -euo pipefail

profile="${1:-release}"
if [[ "$profile" != "debug" && "$profile" != "release" ]]; then
  echo "Uso: $0 [debug|release]" >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
manifest="$script_dir/core/Cargo.toml"
args=(build --locked --manifest-path "$manifest" --features veilid,signal-ratchet)
target_dir="$script_dir/core/target/debug"

if [[ "$profile" == "release" ]]; then
  args+=(--release)
  target_dir="$script_dir/core/target/release"
fi

cargo "${args[@]}"
test -f "$target_dir/libsylphy_core.so"
echo "Core nativo Sylphy Linux pronto: $target_dir/libsylphy_core.so"
