#!/bin/bash
# Setup Python environment with whisperkittools for model conversion
set -e

VENV_DIR="/tmp/whisperkit-env-312"
PYTHON="/opt/homebrew/bin/python3.12"

if [ ! -d "$VENV_DIR" ]; then
    echo "Creating Python 3.12 venv at $VENV_DIR..."
    $PYTHON -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
pip install -q git+https://github.com/argmaxinc/whisperkittools.git
echo "Environment ready. Activate with: source $VENV_DIR/bin/activate"
