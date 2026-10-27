#!/usr/bin/env python3
import argparse,hashlib,json,sqlite3,zipfile
from pathlib import Path
r=Path(__file__).resolve().parents[1];ap=argparse.ArgumentParser();ap.add_argument('--restore-reviewed',action='store_true');args=ap.parse_args()
state=json.loads((r/'19-research-progress/checkpoint.json').read_text());db=sqlite3.connect(r/'data/research.sqlite');db.row_factory=sqlite3.Row
assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
assert hashlib.sha256((r.parents[1]/'1-2300.zip').read_bytes()).hexdigest()==state['source_archive_sha256']
assert db.execute('SELECT count(*) FROM chapters').fetchone()[0]==2397
if args.restore_reviewed:
 for n in state['reviewed_files']:db.execute("UPDATE chapters SET review_status='context_reviewed_initial' WHERE file_number=?",(n,))
 db.commit()
assert [row[0] for row in db.execute("SELECT file_number FROM chapters WHERE review_status='context_reviewed_initial' ORDER BY file_number")]==state['reviewed_files']
for table in ['facts','events']:
 for row in db.execute(f'SELECT * FROM {table}'):
  chapter=db.execute('SELECT lines FROM chapters WHERE id=?',(row['chapter_id'],)).fetchone()
  assert chapter and 1<=row['line_start']<=row['line_end']<=chapter[0],(table,dict(row))
for row in db.execute('SELECT * FROM causal_edges'):
 for key in ['source_event','target_event']:assert db.execute('SELECT 1 FROM events WHERE id=?',(row[key],)).fetchone()
for f in r.glob('data/*.jsonl'):
 for line in f.read_text().splitlines():json.loads(line)
import re
for f in r.rglob('*.md'):
 for link in re.findall(r'\]\(([^)]+)\)',f.read_text()):
  if not re.match(r'\w+://',link):assert (f.parent/link.split('#')[0]).exists(),(f,link)
print('PASS: SQLite integrity, archive hash, 2397 source records, review checkpoint, fact/event source ranges, causal endpoints, JSONL syntax, Markdown links.')
print('This validates infrastructure and references, not completion or literary correctness.')
