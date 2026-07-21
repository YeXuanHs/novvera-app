import subprocess
import os
import httpx

with open("pubspec.yaml", "r", encoding="utf-8") as file:
    content = file.read()

subprocess.run(["flutter", "build", "windows", "--release"], shell=True, check=False)

if os.path.exists("build/app-windows.zip"):
    os.remove("build/app-windows.zip")

version = str.split(str.split(content, "version: ")[1], "+")[0]

subprocess.run(
    [
        "tar",
        "-a",
        "-c",
        "-f",
        f"build/windows/Novvera-{version}-windows-arm64.zip",
        "-C",
        "build/windows/x64/runner/Release",
        "*",
    ],
    shell=True,
)

issPath = "windows/build_arm64.iss"

with open(issPath, "r", encoding="utf-8") as file:
    issContent = file.read()
newContent = issContent
newContent = newContent.replace("{{version}}", version)
newContent = newContent.replace("{{root_path}}", os.getcwd())
with open(issPath, "w", encoding="utf-8", newline="\r\n") as file:
    file.write(newContent)

if not os.path.exists("windows/ChineseSimplified.isl"):
    url = "https://cdn.jsdelivr.net/gh/kira-96/Inno-Setup-Chinese-Simplified-Translation@latest/ChineseSimplified.isl"
    response = httpx.get(url)
    with open("windows/ChineseSimplified.isl", "wb") as file:
        file.write(response.content)

subprocess.run(["iscc", issPath], shell=True)

with open(issPath, "w", encoding="utf-8", newline="\r\n") as file:
    file.write(issContent)
