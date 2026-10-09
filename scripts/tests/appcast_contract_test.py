#!/usr/bin/env python3

import pathlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def main() -> None:
    info = ET.parse(ROOT / "BookSender" / "Info.plist").getroot()
    values = {}
    children = list(info.find("dict"))
    for index in range(0, len(children), 2):
        values[children[index].text] = children[index + 1].text

    assert values["SUFeedURL"] == (
        "https://rckbrcls.com/api/book-sender/appcast.xml"
    )
    assert values["SUPublicEDKey"]
    assert values["SUEnableInstallerLauncherService"] is None

    with tempfile.TemporaryDirectory(prefix="booksender-appcast-") as directory:
        appcast = pathlib.Path(directory) / "appcast.xml"
        appcast.write_text(
            (ROOT / "appcast.xml").read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        subprocess.run(
            [
                "python3",
                str(ROOT / "scripts" / "update_appcast.py"),
                "--appcast",
                str(appcast),
                "--title",
                "Book Sender",
                "--link",
                "https://github.com/rckbrcls/book-sender",
                "--description",
                "Book Sender updates",
                "--language",
                "en",
                "--version",
                "42",
                "--short-version",
                "1.2.3",
                "--minimum-system-version",
                "26.0",
                "--pub-date",
                "Wed, 29 Jul 2026 00:00:00 +0000",
                "--enclosure-url",
                (
                    "https://github.com/rckbrcls/book-sender/releases/download/"
                    "v1.2.3/BookSender-macos-universal-v1.2.3.zip"
                ),
                "--enclosure-length",
                "12345",
                "--ed-signature",
                "test-signature",
                "--release-notes",
                "Controlled contract fixture.",
            ],
            check=True,
        )

        root = ET.parse(appcast).getroot()
        enclosure = root.find("./channel/item/enclosure")
        assert enclosure is not None
        assert enclosure.get("url", "").endswith(
            "/BookSender-macos-universal-v1.2.3.zip"
        )
        assert enclosure.get("length") == "12345"
        assert enclosure.get("type") == "application/zip"
        assert enclosure.get(f"{{{SPARKLE_NS}}}version") == "42"
        assert enclosure.get(f"{{{SPARKLE_NS}}}shortVersionString") == "1.2.3"
        assert enclosure.get(f"{{{SPARKLE_NS}}}edSignature") == "test-signature"
        assert enclosure.get(f"{{{SPARKLE_NS}}}os") == "macos"

    production_paths = [
        ROOT / "BookSender",
        ROOT / "scripts" / "install.sh",
    ]
    forbidden = ("PreviewBook", "Preview Send Book", "FixtureFactory")
    for path in production_paths:
        files = path.rglob("*") if path.is_dir() else [path]
        for file in files:
            if not file.is_file():
                continue
            text = file.read_text(encoding="utf-8", errors="ignore")
            assert not any(token in text for token in forbidden)

    print("Appcast and packaging contracts passed.")


if __name__ == "__main__":
    main()
