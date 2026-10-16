#!/usr/bin/env python3
"""Check generated Bible integrity before release."""
import argparse
import hashlib
import json
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--allow-demo', action='store_true')
    options = parser.parse_args()
    bible = ROOT / 'assets/bible'
    manifest = json.loads((bible / 'dataset_manifest.json').read_text(encoding='utf-8'))
    conn = sqlite3.connect(bible / 'bible.db')
    try:
        total = conn.execute('SELECT COUNT(*) FROM verses').fetchone()[0]
        books = conn.execute('SELECT COUNT(DISTINCT book_id) FROM verses').fetchone()[0]
        rows = conn.execute('SELECT verse_id FROM curated_verses').fetchall()
        violations = conn.execute('PRAGMA foreign_key_check').fetchall()
        assert not violations, violations
        assert total == manifest['verse_count']
        assert len(rows) == manifest['curated_count']
        assert conn.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        assert all(conn.execute('SELECT 1 FROM verses WHERE id = ?', (row[0],)).fetchone()
                   for row in rows)
        is_demo = manifest['edition'] == 'DEMO'
        if is_demo:
            assert options.allow_demo, 'Demo database cannot pass release validation'
        else:
            assert books == 66 and total >= 30000 and len(rows) >= 75
        native_paths = [
            ROOT / 'android/app/src/main/assets/curated_widget.json',
            ROOT / 'ios/LocalWidgetsExtension/curated_widget.json',
        ]
        flutter = (bible / 'curated_widget.json').read_bytes()
        records = json.loads(flutter)
        assert len(records) == len(rows)
        assert all(path.read_bytes() == flutter for path in native_paths)
        print(json.dumps({
            'edition': manifest['edition'], 'books': books,
            'verses': total, 'curated': len(rows),
            'native_assets_identical': True, 'release_ready_data': not is_demo,
        }, indent=2))
    finally:
        conn.close()

if __name__ == '__main__': main()
