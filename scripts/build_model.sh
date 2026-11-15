#!/bin/bash
# Télécharge les poids FaceNet (≈110 Mo, GitHub facenet-pytorch) et produit
# Models/FaceEmbedding.mlmodelc. À lancer une seule fois. Nécessite Python 3.11
# (via `uv` si présent, sinon python3.11) et Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
VENV=.build/model-venv
mkdir -p .build Models
if [ ! -x "$VENV/bin/python" ]; then
  if command -v uv >/dev/null; then uv venv --python 3.11 "$VENV"
  else python3.11 -m venv "$VENV"; fi
fi
PKGS=(torch==2.2.2 torchvision==0.17.2 facenet-pytorch==2.6.0 coremltools==8.1 "numpy<2")
if command -v uv >/dev/null; then uv pip install --python "$VENV/bin/python" "${PKGS[@]}"
else "$VENV/bin/pip" install "${PKGS[@]}"; fi
rm -rf Models/FaceEmbedding.mlpackage Models/FaceEmbedding.mlmodelc
"$VENV/bin/python" scripts/convert_model.py Models/FaceEmbedding.mlpackage
xcrun coremlcompiler compile Models/FaceEmbedding.mlpackage Models/
echo "Modèle prêt : Models/FaceEmbedding.mlmodelc"
