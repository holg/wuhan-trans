#!/bin/bash
# Download Cohere Transcribe CoreML models, compile .mlpackage → .mlmodelc,
# and upload all compiled models to HuggingFace
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_REPO="BarathwajAnandan/cohere-transcribe-03-2026-CoreML-6bit"
DST_REPO="holgt/cohere-transcribe-coreml-compiled"
WORK_DIR="/tmp/cohere-compiled"
DL_DIR="/tmp/cohere-hf-dl"

source /tmp/whisperkit-env-312/bin/activate
mkdir -p "$WORK_DIR"

echo "=== Downloading .mlpackage files ==="
python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('$SRC_REPO', allow_patterns=['cohere_*.mlpackage/*'], local_dir='$DL_DIR')
"

echo "=== Compiling .mlpackage → .mlmodelc ==="
for pkg in "$DL_DIR"/cohere_*.mlpackage; do
    name=$(basename "$pkg" .mlpackage)
    echo "  Compiling $name..."
    xcrun coremlcompiler compile "$pkg" "$WORK_DIR/"
done

echo "=== Downloading existing compiled models ==="
python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('$SRC_REPO', allow_patterns=['.compiled/*.mlmodelc/*'], local_dir='/tmp/cohere-existing')
"

# Copy existing compiled models with simpler names
for model_dir in /tmp/cohere-existing/.compiled/*.mlmodelc; do
    name=$(basename "$model_dir" .mlmodelc)
    # Extract base name: cohere_frontend_gpu_xxx → cohere_frontend
    base=$(echo "$name" | sed 's/_gpu_[0-9]*//')
    echo "  Copying $name → $base.mlmodelc"
    cp -r "$model_dir" "$WORK_DIR/$base.mlmodelc" 2>/dev/null || true
done

echo "=== Downloading manifest ==="
python3 -c "
from huggingface_hub import hf_hub_download
import shutil
path = hf_hub_download('$SRC_REPO', 'coreml_manifest.json')
shutil.copy(path, '$WORK_DIR/coreml_manifest.json')
"

echo "=== Uploading to $DST_REPO ==="
huggingface-cli repo create cohere-transcribe-coreml-compiled --repo-type model 2>/dev/null || true
huggingface-cli upload "$DST_REPO" "$WORK_DIR/coreml_manifest.json" coreml_manifest.json

for model_dir in "$WORK_DIR"/*.mlmodelc; do
    name=$(basename "$model_dir")
    echo "  Uploading $name..."
    huggingface-cli upload "$DST_REPO" "$model_dir" ".compiled/$name/"
done

echo "Done. Models available at https://huggingface.co/$DST_REPO"
