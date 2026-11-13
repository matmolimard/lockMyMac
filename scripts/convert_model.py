"""Convertit FaceNet (InceptionResnetV1, poids VGGFace2) en modèle Core ML.

Entrée  : image RVB 160x160 (visage recadré), normalisée (x-127.5)/128 dans le modèle.
Sortie  : "embedding", vecteur de 512 flottants normalisé L2.
"""
import hashlib, pathlib, sys
import numpy as np
import torch
import coremltools as ct
from facenet_pytorch import InceptionResnetV1

out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "FaceEmbedding.mlpackage")
net = InceptionResnetV1(pretrained="vggface2").eval()
example = torch.rand(1, 3, 160, 160) * 2 - 1
traced = torch.jit.trace(net, example)

mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=(1, 3, 160, 160),
                         scale=1 / 128.0, bias=[-127.5 / 128.0] * 3,
                         color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.macOS13,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.short_description = "FaceNet InceptionResnetV1 (VGGFace2) - empreinte faciale 512-d"
mlmodel.license = "MIT (facenet-pytorch) ; poids entraînés sur VGGFace2"
mlmodel.save(str(out))

# Contrôle : la sortie Core ML doit coller à celle de PyTorch.
from PIL import Image
rgb = (np.random.rand(160, 160, 3) * 255).astype(np.uint8)
ref = net(torch.from_numpy((rgb.astype(np.float32) - 127.5) / 128.0).permute(2, 0, 1)[None]).detach().numpy()[0]
got = np.array(mlmodel.predict({"image": Image.fromarray(rgb)})["embedding"]).reshape(-1)
cos = float(ref @ got / (np.linalg.norm(ref) * np.linalg.norm(got)))
print(f"cosinus PyTorch/CoreML = {cos:.5f}")
for p in pathlib.Path(torch.hub.get_dir()).rglob("*vggface2*.pt"):
    print("poids:", p.name, "sha256", hashlib.sha256(p.read_bytes()).hexdigest())
assert cos > 0.995, "conversion infidèle"
print("OK ->", out)
