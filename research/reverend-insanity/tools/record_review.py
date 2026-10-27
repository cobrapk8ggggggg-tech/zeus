#!/usr/bin/env python3
"""Import a human-curated review packet, then synchronize exports and checkpoints.
Does not read or summarize the novel. Packets are written after contextual reading.
"""
import argparse,json,subprocess,sys
from pathlib import Path
R=Path(__file__).resolve().parents[1]
def main():
 ap=argparse.ArgumentParser();ap.add_argument('packet');a=ap.parse_args();packet=json.loads(Path(a.packet).read_text())
 for table,entries in packet['records'].items():
  if table not in ['facts','entities','events','causal_edges','knowledge','relationships','decisions']:raise ValueError(table)
  p=R/'data'/f'{table}.jsonl';existing={v['id']:v for v in map(json.loads,p.read_text().splitlines())}
  for v in entries:existing[v['id']]=v
  p.write_text(''.join(json.dumps(v,ensure_ascii=False)+'\n' for v in existing.values()))
 p=R/'19-research-progress/checkpoint.json';state=json.loads(p.read_text());state['reviewed_files']=sorted(set(state['reviewed_files'])|set(packet['reviewed_files']));state['next_file']=max(state['reviewed_files'])+1;state['resume_command']=f"python research/reverend-insanity/tools/query.py source {state['next_file']}";state['next_action']=packet['next_action'];state['research_target']=500;state['target_batch_end']=packet['next_batch_end'];p.write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n')
 subprocess.run([sys.executable,str(R/'tools/import_review.py')],check=True)
 subprocess.run([sys.executable,str(R/'tools/validate.py')],check=True)
if __name__=='__main__':main()
