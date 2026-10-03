import importlib.util
import tempfile
import unittest
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("make_appcast", HERE / "make-appcast.py")
make_appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(make_appcast)

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
PUBLISHED = datetime(2026, 10, 2, 22, 0, tzinfo=timezone.utc)


def item_of(xml):
    root = ET.fromstring(xml)
    items = root.findall("./channel/item")
    assert len(items) == 1
    return items[0]


class AppcastTests(unittest.TestCase):
    def build(self, notes=("Fix one", "Fix two"), url="https://example.com/DropUp-0.1.27.dmg", signature="c2ln=="):
        return make_appcast.build_appcast(
            "0.1.27", "57", url, signature, 6029319, "14.0", list(notes), PUBLISHED
        )

    def test_item_carries_what_sparkle_compares_and_checks(self):
        item = item_of(self.build())
        self.assertEqual(item.findtext(f"{SPARKLE}version"), "57")
        self.assertEqual(item.findtext(f"{SPARKLE}shortVersionString"), "0.1.27")
        self.assertEqual(item.findtext(f"{SPARKLE}minimumSystemVersion"), "14.0")
        self.assertEqual(item.findtext("pubDate"), "Fri, 02 Oct 2026 22:00:00 +0000")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://example.com/DropUp-0.1.27.dmg")
        self.assertEqual(enclosure.get("length"), "6029319")
        self.assertEqual(enclosure.get(f"{SPARKLE}edSignature"), "c2ln==")

    def test_notes_become_a_list(self):
        description = item_of(self.build()).findtext("description")
        self.assertEqual(description, "<ul><li>Fix one</li><li>Fix two</li></ul>")

    def test_no_notes_still_says_something(self):
        for notes in ([], ["", "  "]):
            description = item_of(self.build(notes=notes)).findtext("description")
            self.assertEqual(description, f"<ul><li>{make_appcast.NO_NOTES}</li></ul>")

    def test_everything_from_outside_is_escaped(self):
        xml = self.build(
            notes=["<script>alert(1)</script> & ]]> done"],
            url='https://example.com/a"b&c.dmg',
            signature='x"y',
        )
        item = item_of(xml)  # still well formed
        self.assertNotIn("<script>", item.findtext("description"))
        self.assertIn("&lt;script&gt;", item.findtext("description"))
        self.assertEqual(item.find("enclosure").get("url"), 'https://example.com/a"b&c.dmg')
        self.assertEqual(item.find("enclosure").get(f"{SPARKLE}edSignature"), 'x"y')

    def test_command_line_writes_the_file(self):
        with tempfile.TemporaryDirectory() as directory:
            notes = Path(directory) / "notes.txt"
            notes.write_text("One thing\nAnother\n", encoding="utf-8")
            output = Path(directory) / "appcast.xml"
            status = make_appcast.main([
                "--version", "1.0.0", "--build", "9", "--url", "https://example.com/x.dmg",
                "--signature", "abc=", "--length", "10", "--notes", str(notes), "--output", str(output),
            ])
            self.assertEqual(status, 0)
            item = item_of(output.read_text(encoding="utf-8"))
            self.assertEqual(item.findtext(f"{SPARKLE}shortVersionString"), "1.0.0")
            self.assertEqual(item.findtext("description"), "<ul><li>One thing</li><li>Another</li></ul>")


if __name__ == "__main__":
    unittest.main()
