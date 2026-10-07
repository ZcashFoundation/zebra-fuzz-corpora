#!/usr/bin/env python3
"""Package reviewed, minimised equivalence corpora deterministically.

Usage: python3 package-equivalence.py CORPUS_ROOT
CORPUS_ROOT contains one directory per target. Does not upload anything.
"""
import hashlib
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parent
TARGETS = ("orchard_batch_equivalence", "tower_partition_equivalence")


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    for target in TARGETS:
        entries = sorted((source / target).iterdir())
        if not entries or any(not entry.is_file() for entry in entries):
            raise SystemExit(f"expected nonempty flat corpus: {target}")
        archive = ROOT / "seeds" / f"{target}_seed_corpus.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as out:
            for entry in entries:
                data = entry.read_bytes()
                if not data or len(data) > 2_000_001:
                    raise SystemExit(f"invalid input size: {entry.name}")
                info = zipfile.ZipInfo(entry.name, (2026, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                out.writestr(info, data, compresslevel=9)
        print(f"{target}: {len(entries)} entries, {archive.stat().st_size} bytes")
    # This is a generated manifest, including the unchanged original archives.
    lines = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
             for path in sorted((ROOT / "seeds").glob("*.zip"))]
    (ROOT / "SHA256SUMS").write_text("".join(lines))


if __name__ == "__main__":
    main()
