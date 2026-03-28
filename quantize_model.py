"""
Quantizes DepthAnythingV2SmallF16.mlpackage to 8-bit weights.
Typical result: ~2x faster inference, ~2x smaller model file.

Usage:
    pip3 install coremltools
    python3 quantize_model.py
"""

import coremltools as ct
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig,
    OptimizationConfig,
    linear_quantize_weights,
)
import os, sys

SRC = "DepthanythingTest/DepthanythingTest/DepthAnythingV2SmallF16.mlpackage"
DST = "DepthanythingTest/DepthanythingTest/DepthAnythingV2SmallInt8.mlpackage"

if not os.path.exists(SRC):
    print(f"❌ Source model not found at {SRC}")
    print("   Run ./setup_model.sh first.")
    sys.exit(1)

print(f"📦 Loading {SRC} ...")
model = ct.models.MLModel(SRC)

print("⚙️  Applying 8-bit linear weight quantization ...")
op_config = OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
config    = OptimizationConfig(global_config=op_config)
quantized = linear_quantize_weights(model, config=config)

print(f"💾 Saving to {DST} ...")
quantized.save(DST)

orig_mb = sum(
    os.path.getsize(os.path.join(r, f))
    for r, _, files in os.walk(SRC) for f in files
) / 1e6
new_mb = sum(
    os.path.getsize(os.path.join(r, f))
    for r, _, files in os.walk(DST) for f in files
) / 1e6

print(f"\n✅ Done!")
print(f"   Original : {orig_mb:.1f} MB")
print(f"   Quantized: {new_mb:.1f} MB  ({100*new_mb/orig_mb:.0f}% of original)")
print(f"\nNext steps:")
print(f"  1. In Xcode: drag {DST} into the project (same way you added the F16 model)")
print(f"  2. In DepthInferenceEngine.swift change the model name:")
print(f'     let name = "DepthAnythingV2SmallInt8"')
