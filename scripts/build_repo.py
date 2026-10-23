#!/usr/bin/env python3
"""Create a small APT Packages index from the debs in the Pages directory."""

from __future__ import annotations

import gzip
import hashlib
import io
import sys
import tarfile
from pathlib import Path


def control_from_deb(path: Path) -> bytes:
    data = path.read_bytes()
    if not data.startswith(b"!<arch>\n"):
        raise ValueError(f"{path} is not a Debian ar archive")
    offset = 8
    while offset + 60 <= len(data):
        header = data[offset : offset + 60]
        if header[58:60] != b"`\n":
            raise ValueError(f"Malformed ar header in {path}")
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        start = offset + 60
        member = data[start : start + size]
        if name.startswith("control.tar"):
            with tarfile.open(fileobj=io.BytesIO(member), mode="r:*") as archive:
                control = next((item for item in archive.getmembers() if item.name.lstrip("./") == "control"), None)
                if control is None:
                    raise ValueError(f"No control file in {path}")
                extracted = archive.extractfile(control)
                if extracted is None:
                    raise ValueError(f"Could not read control file in {path}")
                return extracted.read().strip() + b"\n"
        offset = start + size + (size & 1)
    raise ValueError(f"No control.tar member in {path}")


def main() -> None:
    site = Path(sys.argv[1] if len(sys.argv) > 1 else "site")
    debs_dir = site / "debs"
    packages = []
    for deb in sorted(debs_dir.glob("*.deb")):
        control = control_from_deb(deb)
        stanza = (
            control
            + f"Filename: debs/{deb.name}\n".encode()
            + f"Size: {deb.stat().st_size}\n".encode()
            + f"SHA256: {hashlib.sha256(deb.read_bytes()).hexdigest()}\n".encode()
        )
        packages.append(stanza)
    if not packages:
        raise SystemExit(f"No .deb packages found in {debs_dir}")
    index = b"\n".join(packages)
    (site / "Packages").write_bytes(index)
    with (site / "Packages.gz").open("wb") as output:
        with gzip.GzipFile(fileobj=output, mode="wb", mtime=0) as compressed:
            compressed.write(index)
    (site / ".nojekyll").touch()
    template = Path(__file__).resolve().parent.parent / "repository-index.html"
    if not template.is_file():
        raise SystemExit(f"Missing repository homepage template: {template}")
    homepage = template.read_text(encoding="utf-8").replace("__PACKAGE_COUNT__", str(len(packages)))
    (site / "index.html").write_text(homepage, encoding="utf-8")
    release_fields = [
        "Origin: m9d2",
        "Label: 网速显示",
        "Suite: stable",
        "Codename: stable",
        "Architectures: iphoneos-arm64e",
        "Components: main",
        "Description: m9d2 RootHide package repository",
    ]
    for algorithm in ("MD5", "SHA1", "SHA256"):
        entries = []
        for filename in ("Packages", "Packages.gz"):
            contents = (site / filename).read_bytes()
            digest = hashlib.new(algorithm.lower(), contents).hexdigest()
            entries.append(f" {digest} {len(contents):>8} {filename}")
        release_fields.append(f"{algorithm}Sum:\n" + "\n".join(entries))
    (site / "Release").write_text("\n".join(release_fields) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
