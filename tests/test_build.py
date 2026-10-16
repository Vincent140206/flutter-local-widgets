"""Unit tests for the offline dataset builder (Python standard library only)."""
import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / 'tools'))
from build_bible_db import BOOK_NAMES, ABBREVIATIONS, LOOKUP, normalize, from_xml_zip

class BuilderTests(unittest.TestCase):
    def test_book_mapping(self):
        self.assertEqual(len(BOOK_NAMES), 66)
        self.assertEqual(len(ABBREVIATIONS), 66)
        self.assertEqual(LOOKUP[normalize('John')], 43)
        self.assertEqual(LOOKUP[normalize('Psalms')], 19)
        self.assertEqual(LOOKUP[normalize('Song of Songs')], 22)

    def test_xml_zip_reader(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'test.zip'
            xml = '''<?xml version="1.0" encoding="utf-8"?>
            <bible><v b="Genesis" c="1" v="1">In the beginning.</v>
            <v b="John" c="3" v="16">For God so loved the world.</v></bible>'''
            with zipfile.ZipFile(path, 'w') as output:
                output.writestr('engwebp_vpl.xml', xml)
            self.assertEqual(list(from_xml_zip(path)), [
                (1, 1, 1, 'In the beginning.'),
                (43, 3, 16, 'For God so loved the world.'),
            ])

    def test_demo_integrity(self):
        db = sqlite3.connect(PROJECT / 'assets/bible/bible.db')
        try:
            count = db.execute('SELECT COUNT(*) FROM verses').fetchone()[0]
            self.assertGreater(count, 0)
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
            row = db.execute('SELECT text FROM verses WHERE id=?', ('JHN.3.16',)).fetchone()
            self.assertIsNotNone(row)
        finally:
            db.close()

    def test_native_pool_bytes_match(self):
        paths = [PROJECT / 'assets/bible/curated_widget.json',
                 PROJECT / 'android/app/src/main/assets/curated_widget.json',
                 PROJECT / 'ios/LocalWidgetsExtension/curated_widget.json']
        self.assertEqual(paths[0].read_bytes(), paths[1].read_bytes())
        self.assertEqual(paths[1].read_bytes(), paths[2].read_bytes())

if __name__ == '__main__': unittest.main()
