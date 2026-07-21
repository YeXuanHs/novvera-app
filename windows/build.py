"""Build / package Novvera for Windows.

Usage:
  python windows/build.py              # flutter build + zip + installer
  python windows/build.py --package-only   # zip + installer only
"""

from __future__ import annotations

import os
import subprocess
import sys

import httpx

PACKAGE_ONLY = "--package-only" in sys.argv


def main() -> int:
    with open("pubspec.yaml", "r", encoding="utf-8") as file:
        content = file.read()

    if not PACKAGE_ONLY:
        result = subprocess.run(
            ["flutter", "build", "windows", "--release"],
            shell=True,
        )
        if result.returncode != 0:
            return result.returncode

    release_dir = "build/windows/x64/runner/Release"
    if not os.path.isdir(release_dir):
        print(f"Release output not found: {release_dir}", file=sys.stderr)
        return 1

    version = str.split(str.split(content, "version: ")[1], "+")[0]
    zip_path = f"build/windows/Novvera-{version}-windows.zip"
    if os.path.exists(zip_path):
        os.remove(zip_path)

    subprocess.run(
        [
            "tar",
            "-a",
            "-c",
            "-f",
            zip_path,
            "-C",
            release_dir,
            "*",
        ],
        shell=True,
        check=False,
    )

    with open("windows/build.iss", "r", encoding="utf-8") as file:
        iss_content = file.read()
    new_content = (
        iss_content.replace("{{version}}", version).replace(
            "{{root_path}}", os.getcwd()
        )
    )
    with open("windows/build.iss", "w", encoding="utf-8", newline="\r\n") as file:
        file.write(new_content)

    if not os.path.exists("windows/ChineseSimplified.isl"):
        url = (
            "https://cdn.jsdelivr.net/gh/kira-96/"
            "Inno-Setup-Chinese-Simplified-Translation@latest/"
            "ChineseSimplified.isl"
        )
        response = httpx.get(url)
        with open("windows/ChineseSimplified.isl", "wb") as file:
            file.write(response.content)

    subprocess.run(["iscc", "windows/build.iss"], shell=True, check=False)

    with open("windows/build.iss", "w", encoding="utf-8", newline="\r\n") as file:
        file.write(iss_content)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
