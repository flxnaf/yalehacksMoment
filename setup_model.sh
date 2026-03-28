#!/bin/bash
# Downloads DepthAnythingV2SmallF16.mlpackage from Hugging Face
# Run once before opening the Xcode project.

set -e

DEST="DepthanythingTest/DepthanythingTest/DepthAnythingV2SmallF16.mlpackage"

if [ -d "$DEST" ]; then
  echo "✅ Model already exists at $DEST"
  exit 0
fi

echo "📦 Downloading Depth Anything V2 Small (Float16) CoreML model..."

if ! command -v huggingface-cli &> /dev/null; then
  echo "⚠️  huggingface-cli not found. Installing via pip..."
  pip3 install --quiet huggingface_hub
fi

huggingface-cli download \
  julien-c/depth-anything-v2-small-hf \
  DepthAnythingV2SmallF16.mlpackage \
  --repo-type model \
  --local-dir "$(dirname "$DEST")" \
  --local-dir-use-symlinks False

echo "✅ Model downloaded to $DEST"
echo "Now open DepthanythingTest/DepthanythingTest.xcodeproj in Xcode."
