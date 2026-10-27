#!/usr/bin/env python3
"""Import explicitly reviewed JSONL records; never infer review from extraction."""
import json,sqlite3
from pathlib import Path
R=Path(__file__).resolve().parents[1]
def main():
 db=sqlite3.connect(R/'data/research.sqlite')
 for table in ['entities','facts','events','causal_edges','knowledge','relationships','decisions']:
  p=R/'data'/f'{table}.jsonl'
  for line in p.read_text().splitlines():
   row=json.loads(line)
   if table=='decisions':row['record_json']=json.dumps(row.pop('record'),ensure_ascii=False)
   cols=list(row)
   db.execute(f'INSERT OR REPLACE INTO {table}({",".join(cols)}) VALUES({",".join("?" for _ in cols)})',[row[k] for k in cols])
 state=json.loads((R/'19-research-progress/checkpoint.json').read_text())
 for n in state['reviewed_files']:db.execute("UPDATE chapters SET review_status='context_reviewed_initial' WHERE file_number=?",(n,))
 db.commit();db.close()
if __name__=='__main__':main()
