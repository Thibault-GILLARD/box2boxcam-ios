#!/bin/bash
# Download the open ball model from Hugging Face and export the stock person and pose models.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
models="$root/PitchLensDockKit/Models"
venv="$root/.venv-models"
mkdir -p "$models"

python3 -m venv "$venv"
# Versions known to export correctly (newer torch breaks coremltools 9.0). numpy is
# pinned too: coremltools 9.0 fails on numpy >= 2.4 ("only 0-dimensional arrays can be
# converted to Python scalars"), and the Ultralytics Core ML export asks for <= 2.3.5.
"$venv/bin/pip" install --quiet huggingface_hub "torch==2.7.1" "torchvision==0.22.1" "ultralytics==8.4.153" "coremltools==9.0" \
    "numpy>=1.26,<=2.3.5"

"$venv/bin/python" - "$models" <<'PY'
import shutil, sys
from pathlib import Path
from huggingface_hub import snapshot_download

folder = Path(snapshot_download("Totorotibo84/box2boxcam-football-ball-detection",
                                allow_patterns=["box2boxcam-ball-v1.0.mlpackage/*"]))
target = Path(sys.argv[1]) / "PitchLensBallSmallV006.mlpackage"
if target.exists():
    shutil.rmtree(target)
shutil.copytree(folder / "box2boxcam-ball-v1.0.mlpackage", target)
print("wrote", target)
PY

(cd "$root/scripts" && "$venv/bin/python" export-person-models.py --destination "$models")
