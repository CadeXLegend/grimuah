#!/usr/bin/env bash
# regenerate examples/ from scratch
set -euo pipefail
cd "$(dirname "$0")"
rm -rf examples
mkdir examples
for preset in $(ls presets/*.json | xargs -n1 basename -s .json); do
  ./zig-out/bin/archicade init "examples/$preset" --preset "$preset" 2>/dev/null <<< ""
  rm -f "examples/$preset/biome.json"
done
echo "regenerated examples/ for all presets"
