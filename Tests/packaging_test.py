"""Regression check for clean, self-contained local packages."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


PROJECT = Path(__file__).resolve().parents[1]


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="keepawake-package-test-") as temporary:
        checkout = Path(temporary) / "KeepAwake"
        shutil.copytree(
            PROJECT,
            checkout,
            ignore=shutil.ignore_patterns(
                ".git", ".codebase-memory", "build", "dist", ".DS_Store"
            ),
        )

        stale_app_file = checkout / "build/Keep Awake.app/Contents/Resources/removed.txt"
        stale_dmg_file = checkout / "build/dmg/removed.txt"
        stale_app_file.parent.mkdir(parents=True)
        stale_dmg_file.parent.mkdir(parents=True)
        stale_app_file.write_text("stale app resource")
        stale_dmg_file.write_text("stale disk image resource")

        subprocess.run([checkout / "scripts/package.sh"], cwd=checkout, check=True)

        assert not stale_app_file.exists(), "build kept a removed app resource"
        assert not stale_dmg_file.exists(), "package staging kept a removed file"

        archive = checkout / "dist/Keep Awake.zip"
        with zipfile.ZipFile(archive) as package:
            names = package.namelist()
        assert not any(Path(name).name.startswith("._") for name in names), names
        assert not any(Path(name).name == ".DS_Store" for name in names), names

        expected = {
            "Keep Awake.app/Contents/Info.plist",
            "Keep Awake.app/Contents/MacOS/KeepAwake",
            "Keep Awake.app/Contents/Resources/AppIcon.icns",
            "Keep Awake.app/Contents/Resources/Help.html",
            "Keep Awake.app/Contents/Resources/KeepAwakeHelper",
        }
        missing = expected.difference(names)
        assert not missing, f"archive is missing: {sorted(missing)}"

    print("PASS clean package has no stale resources or AppleDouble files")


if __name__ == "__main__":
    main()
