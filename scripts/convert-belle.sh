#!/bin/bash
# Convert Belle Whisper Large v3 Chinese from PyTorch to CoreML
# Then upload to HuggingFace repo holgt/belle-whisper-large-v3-zh-coreml
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/../belle-coreml"
HF_REPO="holgt/belle-whisper-large-v3-zh-coreml"
MODEL="BELLE-2/Belle-whisper-large-v3-zh"
MODEL_DIR="BELLE-2_Belle-whisper-large-v3-zh"

source /tmp/whisperkit-env-312/bin/activate

echo "=== Converting $MODEL to CoreML ==="
mkdir -p "$OUTPUT_DIR"
whisperkit-generate-model \
    --model-version "$MODEL" \
    --output-dir "$OUTPUT_DIR"

echo "=== Downloading config files ==="
python3 -c "
from huggingface_hub import hf_hub_download
import shutil
for f in ['config.json', 'generation_config.json']:
    path = hf_hub_download('$MODEL', f)
    shutil.copy(path, '$OUTPUT_DIR/$MODEL_DIR/' + f)
    print(f'Copied {f}')
"

echo "=== Uploading to $HF_REPO ==="
huggingface-cli repo create belle-whisper-large-v3-zh-coreml --repo-type model 2>/dev/null || true
huggingface-cli upload "$HF_REPO" "$OUTPUT_DIR/$MODEL_DIR/" "$MODEL_DIR/"

echo "Done. Model available at https://huggingface.co/$HF_REPO"
