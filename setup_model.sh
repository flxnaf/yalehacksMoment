#!/bin/bash
# Downloads DepthAnythingV2SmallF16.mlpackage from Hugging Face
# Run once before opening the Xcode project.

set -e

SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_ROOT"
# Keep HF caches out of the Xcode-synced app folder (duplicate .mlpackage breaks the build).
export HF_HOME="$SCRIPT_ROOT/.hf-home"
mkdir -p "$HF_HOME"

DEST="NavigatorImpaired/NavigatorImpaired/DepthAnythingV2SmallF16.mlpackage"
APP_DIR="$(dirname "$DEST")"

# Hugging Face may write .cache/ under local-dir; Xcode syncs the whole app folder and would
# compile the same .mlpackage twice ("Multiple commands produce").
cleanup_hf_cache_in_app() {
  rm -rf "$APP_DIR/.cache"
}

if [ -d "$DEST" ]; then
  echo "✅ Model already exists at $DEST"
  cleanup_hf_cache_in_app
  exit 0
fi

echo "📦 Downloading Depth Anything V2 Small (Float16) CoreML model..."

if ! python3 -c "import huggingface_hub" &> /dev/null; then
  echo "⚠️  huggingface_hub not found. Installing via pip..."
  pip3 install --quiet huggingface_hub
fi

python3 -m huggingface_hub.cli.hf download \
  apple/coreml-depth-anything-v2-small \
  --repo-type model \
  --local-dir "$(dirname "$DEST")" \
  --include "DepthAnythingV2SmallF16.mlpackage/*"

cleanup_hf_cache_in_app

echo "✅ Model downloaded to $DEST"
echo "Now open NavigatorImpaired/NavigatorImpaired.xcodeproj in Xcode."
