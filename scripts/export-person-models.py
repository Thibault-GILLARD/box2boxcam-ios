"""Export the stock YOLO26s person detector and YOLO26s-pose model to Core ML for the app.

Ultralytics downloads the stock checkpoints on first use. Requires: pip install ultralytics coremltools
"""
import argparse
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# (Core ML resource name, stock checkpoint, input size, NMS in the model, confidence threshold)
MODELS = [
    ("PitchLensPeople", "yolo26s.pt", 960, True, 0.25),
    ("PitchLensPose", "yolo26s-pose.pt", 384, False, 0.10),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=ROOT / "PitchLensDockKit/Models")
    args = parser.parse_args()
    from ultralytics import YOLO

    args.destination.mkdir(parents=True, exist_ok=True)
    for name, checkpoint, size, nms, conf in MODELS:
        model = YOLO(checkpoint)
        exported = Path(model.export(format="coreml", imgsz=size, nms=nms, quantize=16, conf=conf, device="cpu"))
        target = args.destination / f"{name}.mlpackage"
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(exported, target)
        print("wrote", target)


if __name__ == "__main__":
    main()
