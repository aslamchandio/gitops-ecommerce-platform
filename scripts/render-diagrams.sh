#!/usr/bin/env bash
# Render docs/diagrams/*.mmd -> docs/images/*.png and *.svg using the
# official mermaid-cli Docker image. No local Node/npm install needed.
#
# Usage:   scripts/render-diagrams.sh              # render all
#          scripts/render-diagrams.sh architecture # render one
#
# Output dimensions are tuned for LinkedIn / GitHub social cards
# (1920px wide, dark background matching the diagram theme).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIA_DIR="$REPO_ROOT/docs/diagrams"
OUT_DIR="$REPO_ROOT/docs/images"
mkdir -p "$OUT_DIR"

# Background must match the theme `primaryColor` set in the .mmd
# header so the diagram visually blends with the canvas.
BG="#0b1220"
WIDTH=1920

if [[ $# -gt 0 ]]; then
  DIAGRAMS=("$@")
else
  DIAGRAMS=(architecture release-flow observability)
fi

command -v docker >/dev/null || { echo "ERROR: docker is required"; exit 1; }

for name in "${DIAGRAMS[@]}"; do
  src="$DIA_DIR/$name.mmd"
  if [[ ! -f "$src" ]]; then
    echo "skip: $src not found"
    continue
  fi
  echo "[render] $name"
  for ext in png svg; do
    # MSYS_NO_PATHCONV=1 stops Git Bash on Windows from rewriting the
    # in-container paths like /in/foo.mmd to C:/Program Files/Git/in/...
    # On macOS/Linux it's a no-op.
    MSYS_NO_PATHCONV=1 docker run --rm \
      -v "$DIA_DIR:/in" \
      -v "$OUT_DIR:/out" \
      minlag/mermaid-cli:latest \
      -i "/in/$name.mmd" \
      -o "/out/$name.$ext" \
      -w "$WIDTH" \
      -b "$BG"
  done
done

echo
echo "Rendered to $OUT_DIR:"
ls -la "$OUT_DIR"
