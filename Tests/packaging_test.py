"""Regression check for clean, self-contained local packages."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


PROJECT = Path(__file__).resolve().parents[1]


def run_artifact_check(
    checkout: Path, app: Path, archive: Path | None = None, image: Path | None = None
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            checkout / "scripts/check-release.sh",
            app,
            archive or "",
            image or "",
        ],
        cwd=checkout,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def assert_rejected(result: subprocess.CompletedProcess[str], reason: str) -> None:
    assert result.returncode != 0, f"artifact check accepted {reason}:\n{result.stdout}"


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

        app = checkout / "build/Keep Awake.app"
        image = checkout / "dist/Keep Awake.dmg"
        normal = run_artifact_check(checkout, app, archive, image)
        assert normal.returncode == 0, normal.stdout

        tampered_archive = checkout / "dist/Tampered.zip"
        with zipfile.ZipFile(archive) as source, zipfile.ZipFile(
            tampered_archive, "w"
        ) as destination:
            for info in source.infolist():
                contents = source.read(info.filename)
                if info.filename == "Keep Awake.app/Contents/Resources/Help.html":
                    contents += b"\ntampered\n"
                destination.writestr(info, contents)
        assert_rejected(
            run_artifact_check(checkout, app, tampered_archive),
            "a ZIP with a modified signed resource",
        )

        alternate_app = checkout / "build/Alternate/Keep Awake.app"
        shutil.copytree(app, alternate_app, symlinks=True)
        alternate_help = alternate_app / "Contents/Resources/Help.html"
        alternate_help.write_text(alternate_help.read_text() + "\nalternate release\n")
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", alternate_app],
            check=True,
        )
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", alternate_app],
            check=True,
        )
        alternate_archive = checkout / "dist/Alternate.zip"
        subprocess.run(
            [
                "/usr/bin/ditto",
                "-c",
                "-k",
                "--keepParent",
                "--norsrc",
                "--noextattr",
                alternate_app,
                alternate_archive,
            ],
            check=True,
        )
        assert_rejected(
            run_artifact_check(checkout, app, alternate_archive),
            "a validly signed ZIP containing a different app payload",
        )

        corrupt_image = checkout / "dist/Corrupt.dmg"
        corrupt_image.write_bytes(b"not a disk image")
        assert_rejected(
            run_artifact_check(checkout, app, image=corrupt_image),
            "a corrupt disk image",
        )

    print("PASS package integrity checks accept the release and reject tampered artifacts")


if __name__ == "__main__":
    main()
