#!/usr/bin/env python3
"""Source locator, candidate search, and evidence-aware causal traversal."""
import argparse,json,sqlite3,zipfile
from pathlib import Path
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();s=p.add_subparsers(dest='cmd',required=True)
a=s.add_parser('source');a.add_argument('file_number',type=int);a.add_argument('--start',type=int,default=1);a.add_argument('--end',type=int,default=0)
a=s.add_parser('search');a.add_argument('term');a.add_argument('--limit',type=int,default=20)
a=s.add_parser('dependents');a.add_argument('event_id');a.add_argument('--include-uncertain',action='store_true')
a=s.add_parser('status')
x=p.parse_args();db=sqlite3.connect(R/'data/research.sqlite');db.row_factory=sqlite3.Row
if x.cmd=='source':
 row=db.execute('SELECT * FROM chapters WHERE file_number=?',(x.file_number,)).fetchone()
 if not row:raise SystemExit('Source file not present')
 with zipfile.ZipFile(R.parents[1]/'1-2300.zip') as z:lines=z.read(row['filename']).decode('utf-8-sig').splitlines()
 print(json.dumps(dict(row),ensure_ascii=False))
 for n in range(x.start,min(x.end or len(lines),len(lines))+1):print(f'{n}: {lines[n-1]}')
elif x.cmd=='search':
 for row in db.execute('SELECT chapter_id,kind,line,text,status FROM candidates WHERE text LIKE ? LIMIT ?',('%'+x.term+'%',x.limit)):print(json.dumps(dict(row),ensure_ascii=False))
elif x.cmd=='status':
 for row in db.execute('SELECT review_status,count(*) AS count FROM chapters GROUP BY review_status'):print(dict(row))
elif x.cmd=='dependents':
 allowed=['direct_cause','necessary_condition','contributing_factor']
 if x.include_uncertain:allowed+=['possible_outcome','uncertain']
 marks=','.join('?'*len(allowed))
 sql=f'''WITH RECURSIVE reach(node) AS (SELECT ? UNION SELECT e.target_event FROM causal_edges e JOIN reach r ON e.source_event=r.node WHERE e.relation_type IN ({marks}) AND e.status='reviewed') SELECT e.* FROM causal_edges e JOIN reach r ON e.source_event=r.node WHERE e.relation_type IN ({marks}) AND e.status='reviewed' '''
 for row in db.execute(sql,[x.event_id]+allowed+allowed):print(json.dumps(dict(row),ensure_ascii=False))
