"""
Converts Depth Anything V2 Small from PyTorch → CoreML with Neural Engine optimizations.

The pre-converted model on HuggingFace was built with generic settings.
This script re-exports with:
  - iOS 17 deployment target (ANE supports more ViT ops)
  - Float16 precision throughout
  - Fixed 518x518 input (model's native resolution)
  - mlprogram format (required for ANE on A14+)

Usage:
    pip3 install torch transformers coremltools
    python3 convert_for_ane.py
"""

import torch
import numpy as np
import coremltools as ct
from transformers import AutoModelForDepthEstimation

MODEL_ID  = "depth-anything/Depth-Anything-V2-Small-hf"
OUT_PATH  = "DepthanythingTest/DepthanythingTest/DepthAnythingV2SmallANE.mlpackage"
IMG_SIZE  = 448   # 32x32 = 1024 tokens (power of 2 — required for ANE attention)

print(f"📥 Loading {MODEL_ID} from HuggingFace...")
hf_model = AutoModelForDepthEstimation.from_pretrained(MODEL_ID)
hf_model.eval()

# Replace PyTorch's fused SDPA with explicit matmul+softmax so coremltools
# can map the attention ops to ANE-compatible primitives.
import math
import torch.nn.functional as F_module

def _ane_attention(query, key, value, attn_mask=None, dropout_p=0.0,
                   is_causal=False, scale=None, **kwargs):
    scale_factor = 1.0 / math.sqrt(query.size(-1)) if scale is None else scale
    attn = query @ key.transpose(-2, -1) * scale_factor
    if is_causal:
        mask = torch.ones(query.size(-2), key.size(-2), dtype=torch.bool,
                          device=query.device).tril()
        attn = attn.masked_fill(~mask, float('-inf'))
    if attn_mask is not None:
        attn = attn + attn_mask
    attn = torch.softmax(attn, dim=-1)
    return attn @ value

F_module.scaled_dot_product_attention = _ane_attention

# Also patch the bicubic upsampler (already done below, but keep this comment)

# coremltools can't convert upsample_bicubic2d — patch all interpolate calls
# in the DPT decoder to use bilinear instead (visually identical for depth maps).
import torch.nn.functional as F
_orig_interpolate = F.interpolate
def _bilinear_interpolate(*args, **kwargs):
    if kwargs.get("mode") == "bicubic":
        kwargs["mode"] = "bilinear"
        kwargs["align_corners"] = False
        kwargs.pop("antialias", None)
    return _orig_interpolate(*args, **kwargs)
F.interpolate = _bilinear_interpolate

# Bake ImageNet normalization into the model so Vision can feed raw [0,1] pixels.
# ct.ImageType with scale=1/255 delivers [0,1] range; we normalise to ImageNet stats here.
class DepthWrapper(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1,3,1,1))
        self.register_buffer("std",  torch.tensor([0.229, 0.224, 0.225]).view(1,3,1,1))
    def forward(self, x):           # x: [0,1] float32
        x = (x - self.mean) / self.std
        return self.m(pixel_values=x).predicted_depth.unsqueeze(1)

wrapper = DepthWrapper(hf_model)
dummy   = torch.zeros(1, 3, IMG_SIZE, IMG_SIZE)  # [0,1] range

print("🔍 Tracing model...")
with torch.no_grad():
    traced = torch.jit.trace(wrapper, dummy)
traced.eval()
traced = torch.jit.freeze(traced)

print("⚙️  Converting to CoreML (iOS 17, Float16, mlprogram)...")
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(
        name="image",
        shape=(1, 3, IMG_SIZE, IMG_SIZE),
        scale=1/255.0,          # Vision delivers [0,255] → we receive [0,1]
        color_layout=ct.colorlayout.RGB,
    )],
    outputs=[ct.TensorType(name="depth", dtype=np.float32)],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
    convert_to="mlprogram",
)

# Add metadata
mlmodel.short_description = "Depth Anything V2 Small — ANE optimized"
mlmodel.input_description["image"]  = "RGB image, normalized 0-1, 518x518"
mlmodel.output_description["depth"] = "Relative depth map, 1x518x518"

print(f"💾 Saving to {OUT_PATH} ...")
mlmodel.save(OUT_PATH)

import os
size_mb = sum(
    os.path.getsize(os.path.join(r, f))
    for r, _, files in os.walk(OUT_PATH) for f in files
) / 1e6
print(f"\n✅ Done! Size: {size_mb:.1f} MB")
print(f"\nNext steps:")
print(f"  1. Drag {OUT_PATH} into Xcode project navigator (same target)")
print(f'  2. In DepthInferenceEngine.swift set: let name = "DepthAnythingV2SmallANE"')
print(f"  3. Build and run — check logs for 'units=0' (Neural Engine)")
