#!/usr/bin/env python3
"""Package a real Xcode-built .app into an unsigned IPA.

This script deliberately does not synthesize a Mach-O executable. An IPA is
only useful when its executable contains the compiled application; a placeholder
binary can look like an archive but will never run on an iPhone.
"""
from __future__ import annotations

import argparse
import plistlib
import shutil
import struct
import tempfile
import zipfile
from pathlib import Path


def is_macho_arm64(path: Path) -> bool:
    try:
        with path.open("rb") as stream:
            header = stream.read(8)
        if len(header) < 8:
            return False
        magic, cpu_type = struct.unpack("<II", header)
        # MH_MAGIC_64 little-endian and CPU_TYPE_ARM64.
        return magic == 0xFEEDFACF and cpu_type == 0x0100000C
    except OSError:
        return False


def package_ipa(app_path: Path, output_path: Path) -> None:
    app_path = app_path.resolve()
    output_path = output_path.resolve()
    if not app_path.is_dir() or app_path.suffix != ".app":
        raise SystemExit(f"ERROR: --app must point to a built .app bundle: {app_path}")

    info_path = app_path / "Info.plist"
    if not info_path.is_file():
        raise SystemExit(f"ERROR: Missing Info.plist in {app_path}")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)

    executable_name = info.get("CFBundleExecutable")
    bundle_id = info.get("CFBundleIdentifier")
    if not executable_name or not bundle_id:
        raise SystemExit("ERROR: Info.plist must contain CFBundleExecutable and CFBundleIdentifier")
    executable = app_path / executable_name
    if not executable.is_file():
        raise SystemExit(f"ERROR: App executable not found: {executable}")
    if executable.stat().st_size < 1_000_000:
        raise SystemExit(
            f"ERROR: Executable is only {executable.stat().st_size:,} bytes; refusing to package a likely placeholder binary."
        )
    if not is_macho_arm64(executable):
        raise SystemExit("ERROR: Executable is not a little-endian arm64 Mach-O binary. Build for generic/platform=iOS.")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="metalcraftpro-ipa-") as temporary:
        payload = Path(temporary) / "Payload"
        payload.mkdir()
        shutil.copytree(app_path, payload / app_path.name, symlinks=True)
        with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(payload.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(Path(temporary)).as_posix())

    with zipfile.ZipFile(output_path) as archive:
        bad_member = archive.testzip()
        if bad_member:
            output_path.unlink(missing_ok=True)
            raise SystemExit(f"ERROR: IPA archive validation failed at {bad_member}")
    print(f"Created unsigned IPA: {output_path}")
    print(f"Bundle ID: {bundle_id}")
    print(f"Executable size: {executable.stat().st_size:,} bytes")
    print("Note: unsigned IPAs require signing or a compatible sideloading workflow before installation.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Path to a real Xcode-built .app bundle")
    parser.add_argument("--output", required=True, type=Path, help="Destination .ipa path")
    args = parser.parse_args()
    package_ipa(args.app, args.output)


if __name__ == "__main__":
    main()
