#!/usr/bin/env python3
"""Build a fully offline WEB SQLite asset from the official eBible VPL XML.

A ONE-TIME developer download is required. No runtime networking exists.
The input ZIP should contain engwebp_vpl.xml.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import sqlite3
import urllib.request
import zipfile
from pathlib import Path
import xml.etree.ElementTree as ET

from curated_references import TOPICS

ROOT = Path(__file__).resolve().parents[1]
SOURCE_URL = 'https://ebible.org/Scriptures/engwebp_vpl.zip'
BOOK_NAMES = [
    'Genesis', 'Exodus', 'Leviticus', 'Numbers', 'Deuteronomy',
    'Joshua', 'Judges', 'Ruth', '1 Samuel', '2 Samuel', '1 Kings',
    '2 Kings', '1 Chronicles', '2 Chronicles', 'Ezra', 'Nehemiah',
    'Esther', 'Job', 'Psalms', 'Proverbs', 'Ecclesiastes',
    'Song of Solomon', 'Isaiah', 'Jeremiah', 'Lamentations',
    'Ezekiel', 'Daniel', 'Hosea', 'Joel', 'Amos', 'Obadiah',
    'Jonah', 'Micah', 'Nahum', 'Habakkuk', 'Zephaniah', 'Haggai',
    'Zechariah', 'Malachi', 'Matthew', 'Mark', 'Luke', 'John',
    'Acts', 'Romans', '1 Corinthians', '2 Corinthians', 'Galatians',
    'Ephesians', 'Philippians', 'Colossians', '1 Thessalonians',
    '2 Thessalonians', '1 Timothy', '2 Timothy', 'Titus',
    'Philemon', 'Hebrews', 'James', '1 Peter', '2 Peter',
    '1 John', '2 John', '3 John', 'Jude', 'Revelation'
]
ABBREVIATIONS = [
    'GEN','EXO','LEV','NUM','DEU','JOS','JDG','RUT','1SA','2SA','1KI',
    '2KI','1CH','2CH','EZR','NEH','EST','JOB','PSA','PRO','ECC','SNG',
    'ISA','JER','LAM','EZK','DAN','HOS','JOL','AMO','OBA','JON','MIC',
    'NAM','HAB','ZEP','HAG','ZEC','MAL','MAT','MRK','LUK','JHN',
    'ACT','ROM','1CO','2CO','GAL','EPH','PHP','COL','1TH','2TH',
    '1TI','2TI','TIT','PHM','HEB','JAS','1PE','2PE','1JN',
    '2JN','3JN','JUD','REV'
]
ALIAS = {'Psalm': 'Psalms', 'Song of Songs': 'Song of Solomon',
         'Canticles': 'Song of Solomon', 'Revelation of John': 'Revelation'}

def normalize(s: str) -> str:
    return re.sub(r'[^a-z0-9]', '', s.lower())

LOOKUP = {normalize(s): i + 1 for i, s in enumerate(BOOK_NAMES)}
for old, new in ALIAS.items():
    LOOKUP[normalize(old)] = LOOKUP[normalize(new)]
for i, abb in enumerate(ABBREVIATIONS, 1):
    LOOKUP[normalize(abb)] = i

def download_source(cache: Path) -> Path:
    cache.parent.mkdir(parents=True, exist_ok=True)
    if cache.exists():
        return cache
    print(f'Downloading official WEB text once: {SOURCE_URL}')
    request = urllib.request.Request(
        SOURCE_URL,
        headers={
            'User-Agent': 'StillOfflineBibleBuilder/1.0 (+https://ebible.org/)',
            'Accept': 'application/zip,application/octet-stream;q=0.9,*/*;q=0.1',
        },
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        content = response.read()
    if not zipfile.is_zipfile(__import__('io').BytesIO(content)):
        raise ValueError('eBible download is not a valid ZIP')
    cache.write_bytes(content)
    return cache

def from_xml_zip(source: Path):
    with zipfile.ZipFile(source) as archive:
        names = [name for name in archive.namelist()
                 if name.lower().endswith('_vpl.xml')]
        if not names:
            names = [name for name in archive.namelist()
                     if name.lower().endswith('.xml')]
        if len(names) != 1:
            raise ValueError(f'Expected one VPL XML file, got {names}')
        with archive.open(names[0]) as fh:
            for event, item in ET.iterparse(fh, events=('end',)):
                if item.tag.split('}')[-1] != 'v':
                    continue
                raw_book = item.attrib['b'].strip()
                book_id = LOOKUP.get(normalize(raw_book))
                if book_id is None:
                    raise ValueError(f'Unrecognized Bible book: {raw_book!r}')
                chapter = int(item.attrib['c'])
                verse = int(item.attrib['v'])
                # No paraphrasing: preserve source words; normalize layout spaces only.
                text = ' '.join(''.join(item.itertext()).split())
                if text:
                    yield book_id, chapter, verse, text
                item.clear()

def schema(conn: sqlite3.Connection):
    conn.executescript('''
        PRAGMA foreign_keys = ON;
        CREATE TABLE books (
            id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE,
            abbrev TEXT NOT NULL UNIQUE, testament TEXT NOT NULL,
            position INTEGER NOT NULL UNIQUE
        );
        CREATE TABLE verses (
            id TEXT PRIMARY KEY,
            book_id INTEGER NOT NULL REFERENCES books(id),
            chapter INTEGER NOT NULL,
            verse INTEGER NOT NULL,
            text TEXT NOT NULL,
            UNIQUE(book_id, chapter, verse)
        );
        CREATE INDEX ix_verses_chapter ON verses(book_id, chapter, verse);
        CREATE TABLE curated_verses (
            verse_id TEXT PRIMARY KEY REFERENCES verses(id),
            topic TEXT NOT NULL,
            position INTEGER NOT NULL
        );
        CREATE INDEX ix_curated_topic ON curated_verses(topic);
        CREATE TABLE favorites (
            verse_id TEXT PRIMARY KEY REFERENCES verses(id),
            created_at TEXT NOT NULL
        );
        CREATE TABLE watchlist (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            watched INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        );
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    ''')
    conn.executemany('INSERT INTO books VALUES (?, ?, ?, ?, ?)', [
        (i + 1, name, ABBREVIATIONS[i], 'OT' if i < 39 else 'NT', i + 1)
        for i, name in enumerate(BOOK_NAMES)
    ])

def build(rows: list[tuple[int,int,int,str]], full: bool, source_hash: str = "demo"):
    assets = ROOT / 'assets' / 'bible'
    assets.mkdir(parents=True, exist_ok=True)
    db_path = assets / 'bible.db'
    if db_path.exists():
        db_path.unlink()
    conn = sqlite3.connect(db_path)
    try:
        schema(conn)
        records = []
        for book, chapter, verse, text in rows:
            if book not in range(1, 67) or chapter < 1 or verse < 1:
                raise ValueError((book, chapter, verse))
            key = f'{ABBREVIATIONS[book-1]}.{chapter}.{verse}'
            records.append((key, book, chapter, verse, text))
        conn.executemany('INSERT INTO verses VALUES (?, ?, ?, ?, ?)', records)
        verse_count = conn.execute('SELECT COUNT(*) FROM verses').fetchone()[0]
        book_count = conn.execute('SELECT COUNT(DISTINCT book_id) FROM verses').fetchone()[0]
        print(f'Imported {verse_count} verses from {book_count} books')
        if full and (verse_count < 30000 or book_count != 66):
            raise ValueError('Dataset is incomplete; expected >30,000 verses and 66 books')
        chosen: dict[str, str] = {}
        for topic, references in TOPICS.items():
            for reference in references:
                match = re.fullmatch(r'(.+) (\d+):(\d+)', reference)
                if not match:
                    raise ValueError(f'Invalid reference: {reference}')
                name, chapter_s, verse_s = match.groups()
                book_id = LOOKUP[normalize(name)]
                verse_id = f'{ABBREVIATIONS[book_id-1]}.{chapter_s}.{verse_s}'
                row = conn.execute('SELECT text FROM verses WHERE id=?', (verse_id,)).fetchone()
                if row and 12 <= len(row[0]) <= 250:
                    chosen.setdefault(verse_id, topic)
        # Deterministic shuffled cycle with no repetition until the pool resets.
        pool = list(chosen.items())
        random.Random(20261016).shuffle(pool)
        if full and len(pool) < 75:
            raise ValueError(f'Only {len(pool)} curated matches; inspect source')
        payload = []
        for pos, (verse_id, topic) in enumerate(pool):
            conn.execute('INSERT INTO curated_verses VALUES (?, ?, ?)',
                         (verse_id, topic, pos))
            row = conn.execute('''
               SELECT b.name, v.chapter, v.verse, v.text FROM verses v
               JOIN books b ON b.id=v.book_id WHERE v.id=?''', (verse_id,)).fetchone()
            payload.append({
                'id': verse_id, 'reference': f'{row[0]} {row[1]}:{row[2]}',
                'text': row[3], 'topic': topic
            })
        widget_path = assets / 'curated_widget.json'
        widget_path.write_text(json.dumps(payload, ensure_ascii=False,
                                          separators=(',', ':')), encoding='utf-8')
        android_asset = ROOT / 'android/app/src/main/assets/curated_widget.json'
        android_asset.parent.mkdir(parents=True, exist_ok=True)
        android_asset.write_bytes(widget_path.read_bytes())
        ios_asset = ROOT / 'ios/LocalWidgetsExtension/curated_widget.json'
        ios_asset.parent.mkdir(parents=True, exist_ok=True)
        ios_asset.write_bytes(widget_path.read_bytes())
        conn.execute('INSERT INTO settings VALUES (?, ?)', ('dataset_type', 'full' if full else 'demo'))
        conn.execute('INSERT INTO settings VALUES (?, ?)', ('dataset_hash', source_hash))
        conn.execute('INSERT INTO settings VALUES (?, ?)', ('translation', 'WEBP' if full else 'DEMO'))
        conn.commit()
        (assets / 'dataset_manifest.json').write_text(json.dumps({
            'edition': 'WEBP' if full else 'DEMO',
            'hash': source_hash,
            'verse_count': verse_count, 'curated_count': len(payload)
        }, indent=2), encoding='utf-8')
        print(f'Curated {len(payload)} verses; total DB size {db_path.stat().st_size:,} bytes')
    except Exception:
        conn.close()
        if db_path.exists(): db_path.unlink()
        raise
    else:
        conn.close()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, help='Local ZIP from eBible; no download')
    parser.add_argument('--demo', action='store_true', help='Create a 12-verse TEST DB only')
    args = parser.parse_args()
    if args.demo:
        examples = [
            ('Genesis',1,1,'In the beginning, God created the heavens and the earth.'),
            ('Psalms',23,1,'The LORD is my shepherd; I shall lack nothing.'),
            ('Psalms',46,10,'Be still, and know that I am God.'),
            ('Proverbs',3,5,'Trust in the LORD with all your heart.'),
            ('Isaiah',41,10,'Don’t you be afraid, for I am with you.'),
            ('Matthew',6,33,'But seek first God’s Kingdom and his righteousness.'),
            ('John',3,16,'For God so loved the world, that he gave his one and only Son.'),
            ('John',14,27,'Peace I leave with you. My peace I give to you.'),
            ('Romans',8,28,'We know that all things work together for good for those who love God.'),
            ('Romans',12,12,'Rejoicing in hope, enduring in troubles, continuing steadfastly in prayer.'),
            ('Philippians',4,13,'I can do all things through Christ, who strengthens me.'),
            ('1 Thessalonians',5,16,'Rejoice always.'),
        ]
        rows = [(LOOKUP[normalize(book)], chap, verse, text)
                for book, chap, verse, text in examples]
        print('WARNING: Building DEMO data, NOT the full WEB.')
        build(rows, full=False)
    else:
        path = args.source or download_source(ROOT / 'tools' / 'cache' / 'engwebp_vpl.zip')
        build(list(from_xml_zip(path)), full=True, source_hash=hashlib.sha256(path.read_bytes()).hexdigest())

if __name__ == '__main__':
    main()
