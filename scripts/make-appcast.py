#!/usr/bin/env python3
"""Writes the Sparkle appcast for one release.

DropUp's updater reads the appcast attached to the latest GitHub release, so the feed only ever has to describe
that one release: a single item, the newest version.

    make-appcast.py --version 0.1.27 --build 57 --url https://…/DropUp-0.1.27.dmg \
        --signature <edSignature> --length 6029319 --notes notes.txt --output appcast.xml

`--notes` is a text file with one change per line. Everything that goes into the feed is escaped.
"""
import argparse
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

NO_NOTES = "Fixes and improvements."


def release_notes_html(lines):
    items = [line.strip() for line in lines if line.strip()]
    if not items:
        items = [NO_NOTES]
    return "<ul>" + "".join(f"<li>{escape(item)}</li>" for item in items) + "</ul>"


def build_appcast(version, build, url, signature, length, minimum_system, notes, published):
    # Escaped HTML never contains "]]>", so it can sit in a CDATA section.
    description = release_notes_html(notes)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DropUp</title>
    <item>
      <title>{escape(f"Version {version}")}</title>
      <pubDate>{format_datetime(published)}</pubDate>
      <sparkle:version>{escape(str(build))}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum_system)}</sparkle:minimumSystemVersion>
      <description><![CDATA[{description}]]></description>
      <enclosure url={quoteattr(url)} length={quoteattr(str(length))} type="application/octet-stream" sparkle:edSignature={quoteattr(signature)}/>
    </item>
  </channel>
</rss>
"""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", required=True, help="the version people see, like 0.1.27")
    parser.add_argument("--build", required=True, help="the build number (CFBundleVersion) Sparkle compares")
    parser.add_argument("--url", required=True, help="where the DMG can be downloaded")
    parser.add_argument("--signature", required=True, help="the DMG's EdDSA signature from sign_update")
    parser.add_argument("--length", required=True, help="the DMG's size in bytes")
    parser.add_argument("--minimum-system", default="14.0")
    parser.add_argument("--notes", help="text file with one change per line")
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)

    notes = Path(args.notes).read_text(encoding="utf-8").splitlines() if args.notes else []
    appcast = build_appcast(
        args.version, args.build, args.url, args.signature, args.length,
        args.minimum_system, notes, datetime.now(timezone.utc),
    )
    Path(args.output).write_text(appcast, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
