#!/usr/bin/env python3
"""Assemble the SwiftPM executable into the same app layout Xcode produces."""

import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Sources/Assets.xcassets"


def setting(name: str) -> str:
    project = (ROOT / "project.yml").read_text()
    match = re.search(rf"^\s*{name}:\s*\"([^\"]+)\"", project, re.MULTILINE)
    if not match:
        raise RuntimeError(f"Missing {name} in project.yml")
    return match.group(1)


def write_info_plist(contents: Path) -> None:
    with (ROOT / "Sources/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    info.update({
        "CFBundleExecutable": "Codenotch",
        "CFBundleIdentifier": "com.vinz.codenotch",
        "CFBundleShortVersionString": setting("MARKETING_VERSION"),
        "CFBundleVersion": setting("CURRENT_PROJECT_VERSION"),
        "CFBundleIconFile": "AppIcon.icns",
        "NSHighResolutionCapable": True,
    })
    with (contents / "Info.plist").open("wb") as target:
        plistlib.dump(info, target)


def write_localizations(resources: Path) -> None:
    catalog = json.loads((ROOT / "Sources/Localizable.xcstrings").read_text())
    translations: dict[str, dict[str, str]] = {"en": {}}
    for key, entry in catalog["strings"].items():
        translations["en"][key] = key
        for language, localized in entry.get("localizations", {}).items():
            value = localized.get("stringUnit", {}).get("value")
            if value is not None:
                translations.setdefault(language, {})[key] = value
    for language, strings in translations.items():
        directory = resources / f"{language}.lproj"
        directory.mkdir()
        with (directory / "Localizable.strings").open("wb") as target:
            plistlib.dump(strings, target, fmt=plistlib.FMT_BINARY)


def write_icons(resources: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="codenotch-icon-") as scratch:
        iconset = Path(scratch) / "AppIcon.iconset"
        iconset.mkdir()
        for image in (ASSETS / "AppIcon.appiconset").glob("*.png"):
            shutil.copy2(image, iconset / image.name)
        subprocess.run(["/usr/bin/iconutil", "-c", "icns", "--output",
                        str(resources / "AppIcon.icns"), str(iconset)], check=True)

    for imageset in ASSETS.glob("*.imageset"):
        metadata = json.loads((imageset / "Contents.json").read_text())
        image = next((item.get("filename") for item in metadata["images"]
                      if item.get("filename")), None)
        if image is None:
            continue
        source = imageset / image
        target = resources / f"{imageset.stem}.png"
        if source.suffix.lower() == ".png":
            shutil.copy2(source, target)
        elif source.suffix.lower() == ".svg":
            subprocess.run(["/usr/bin/sips", "-s", "format", "png", str(source),
                            "--out", str(target)], check=True, capture_output=True)
        else:
            raise RuntimeError(f"Unsupported image asset: {source}")


def main() -> None:
    executable = Path(sys.argv[1]).resolve()
    app = Path(sys.argv[2]).resolve()
    if not executable.is_file():
        raise RuntimeError(f"SwiftPM did not produce {executable}")
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(executable, macos / "Codenotch")
    write_info_plist(contents)
    write_localizations(resources)
    write_icons(resources)
    shutil.copy2(ROOT / "Sources/Resources/LobeIcons-LICENSE.txt", resources)
    (contents / "PkgInfo").write_text("APPL????")


if __name__ == "__main__":
    main()
