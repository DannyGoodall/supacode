import hashlib
import json
import sys
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: generate_release_checksums.py TAG OUTPUT ASSET...")

    tag = sys.argv[1]
    output = Path(sys.argv[2])
    assets = {}
    asset_paths = sorted({Path(path) for path in sys.argv[3:]}, key=lambda path: path.name)

    for asset in asset_paths:
        if not asset.is_file():
            continue
        assets[asset.name] = {
            "sha256": sha256(asset),
            "size": asset.stat().st_size,
        }

    manifest = {"assets": assets, "tag": tag}
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
