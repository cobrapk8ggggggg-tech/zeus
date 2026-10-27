#!/usr/bin/env python3
"""Reproducible source inventory; machine candidates never imply reviewed facts."""
import argparse,collections,hashlib,json,re,sqlite3,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
DIRS=['02-world-encyclopedia','03-gu-system','04-cultivation-paths','05-characters','06-fang-yuan','07-fang-zheng','08-factions','09-timelines','10-events','11-causal-graph','12-knowledge-states','13-narrative-techniques','14-new-protagonist','15-power-system-proposals','16-divergence-simulator','17-consistency-audits','18-open-questions','19-research-progress','20-final-reference','data']
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--archive',default=str(ROOT.parents[1]/'1-2300.zip'));args=ap.parse_args()
 for d in DIRS:
  p=ROOT/d;p.mkdir(exist_ok=True)
  readme=p/'README.md'
  if not readme.exists():readme.write_text('# '+d+'\n\nالحالة: لم تكتمل الدراسة. وجود المجلد لا يعني مراجعة محتواه أو اكتمال شروط القبول.\n',encoding='utf-8')
 db=sqlite3.connect(ROOT/'data/research.sqlite');db.executescript('''
 CREATE TABLE IF NOT EXISTS chapters(id TEXT PRIMARY KEY,archive_entry INTEGER,filename TEXT,file_number INTEGER,true_chapter_number INTEGER,title TEXT,sha256 TEXT,normalized_sha256 TEXT,encoding TEXT,words INTEGER,lines INTEGER,flags TEXT,review_status TEXT DEFAULT 'unreviewed');
 CREATE TABLE IF NOT EXISTS candidates(id TEXT PRIMARY KEY,chapter_id TEXT,kind TEXT,line INTEGER,text TEXT,status TEXT DEFAULT 'unverified',FOREIGN KEY(chapter_id) REFERENCES chapters(id));
 CREATE TABLE IF NOT EXISTS facts(id TEXT PRIMARY KEY,subject TEXT,predicate TEXT,value TEXT,epistemic_type TEXT,confidence TEXT,chapter_id TEXT,line_start INTEGER,line_end INTEGER,status TEXT);
 CREATE TABLE IF NOT EXISTS entities(id TEXT PRIMARY KEY,kind TEXT,canonical_name TEXT,aliases_json TEXT);
 CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,timeline TEXT,description TEXT,chapter_id TEXT,line_start INTEGER,line_end INTEGER,confidence TEXT);
 CREATE TABLE IF NOT EXISTS causal_edges(id TEXT PRIMARY KEY,source_event TEXT,target_event TEXT,relation_type TEXT,evidence TEXT,confidence TEXT,status TEXT);
 CREATE TABLE IF NOT EXISTS knowledge(id TEXT PRIMARY KEY,character_id TEXT,valid_from TEXT,valid_until TEXT,epistemic_type TEXT,proposition TEXT,source_ref TEXT,confidence TEXT);
 CREATE TABLE IF NOT EXISTS relationships(id TEXT PRIMARY KEY,subject TEXT,object TEXT,relation TEXT,valid_from TEXT,valid_until TEXT,source_ref TEXT,confidence TEXT);
 CREATE TABLE IF NOT EXISTS decisions(id TEXT PRIMARY KEY,character_id TEXT,chapter_id TEXT,record_json TEXT,status TEXT);
 ''')
 db.execute('DELETE FROM candidates');db.execute('DELETE FROM chapters')
 rows=[];groups=collections.defaultdict(list);norm=collections.defaultdict(list);nums=[];decode_errors=[]
 patterns={'characters':r'فانغ يوان|فانغ تشينغ|باي نينغ بينغ','locations':r'جبل\s+\S+(?:\s+\S+)?|قرية\s+\S+(?:\s+\S+)?','gu':r'غو\s+\S+(?:\s+\S+){0,3}','cultivation':r'المرتبة\s+\S+|الدرجة\s+[ABCDA-Z]|علامات الداو','factions':r'عشيرة\s+\S+|طائفة\s+\S+|محكمة السماء','time':r'عام|سنة|ليلة|غدًا|سابق|الماضي|المستقبل','relationships':r'أخيه|أخوه|حليف|عدو|عمه|عمته','event':r'قتل|مات|صقل|حصل|اكتشف|قرر|اختار|هاجم','secrets':r'سرّ|أسرار|سرًا|اكتشف|أخفى','heaven_fate':r'إرادة السماء|القدر','possible_contradiction':r'ولكن|اعتقد|ظن|لم يكن يعلم'}
 with zipfile.ZipFile(args.archive) as z:
  bad=z.testzip();infos=z.infolist()
  for idx,info in enumerate(infos,1):
   if info.is_dir():continue
   raw=z.read(info);errors=[]
   try:t=raw.decode('utf-8-sig');enc='utf-8'
   except UnicodeDecodeError:
    enc='undecodable';t=raw.decode('utf-8',errors='replace');decode_errors.append(info.filename);errors.append('decode_error')
   m=re.fullmatch(r'(\d+)\.txt',info.filename);num=int(m[1]) if m else None
   if num is not None:nums.append(num)
   lines=t.splitlines();heading=[(i,l.strip()) for i,l in enumerate(lines[:12],1) if re.match(r'^\s*(?:الفصل\s+\d+|Chapter\s+\d+)',l,re.I)]
   true=None;title=None
   if heading:
    title=heading[0][1];hm=re.search(r'\d+',title);true=int(hm[0]) if hm else None
   else:errors.append('no_explicit_header')
   if true is not None and true!=num:errors.append('number_mismatch')
   if re.search(r'[\u3400-\u9fff]',t):errors.append('cjk_residue')
   if '\ufffd' in t:errors.append('replacement_character')
   if len(t.split())<200:errors.append('short_text_needs_review')
   if t.rstrip() and t.rstrip()[-1] not in '.!؟?…»”\'\":؛)':errors.append('ending_needs_review')
   if re.search(r'https?://|تليجرام|بترجمة',t):errors.append('editorial_material')
   h=hashlib.sha256(raw).hexdigest();nh=hashlib.sha256(re.sub(r'\s+',' ',t).strip().encode()).hexdigest()
   cid=f'SRC-{idx:04d}';groups[h].append(cid);norm[nh].append(cid)
   row=dict(id=cid,archive_entry=idx,filename=info.filename,file_number=num,true_chapter_number=true,title=title,sha256=h,normalized_sha256=nh,encoding=enc,words=len(t.split()),lines=len(lines),flags=errors,review_status='unreviewed')
   rows.append(row)
   db.execute('INSERT INTO chapters VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',tuple(json.dumps(row[k],ensure_ascii=False) if k=='flags' else row[k] for k in row))
   for ln,line in enumerate(lines,1):
    for kind,p in patterns.items():
     if re.search(p,line):
      ident=f'{cid}-{kind}-{ln}'
      db.execute('INSERT INTO candidates(id,chapter_id,kind,line,text) VALUES(?,?,?,?,?)',(ident,cid,kind,ln,json.dumps(sorted(set(m.group(0) for m in re.finditer(p,line))),ensure_ascii=False)))
 db.commit();count=db.execute('SELECT count(*) FROM candidates').fetchone()[0];db.close()
 (ROOT/'data/chapters.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows),encoding='utf-8')
 missing=sorted(set(range(min(nums),max(nums)+1))-set(nums));flags=collections.Counter(f for r in rows for f in r['flags'])
 summary=dict(archive_sha256=hashlib.sha256(Path(args.archive).read_bytes()).hexdigest(),crc_bad_entry=bad,archive_entries=len(infos),files=len(rows),min_file_number=min(nums),max_file_number=max(nums),missing_file_numbers=missing,duplicate_file_numbers=[n for n,c in collections.Counter(nums).items() if c>1],exact_duplicate_groups=[v for v in groups.values() if len(v)>1],normalized_duplicate_groups=[v for v in norm.values() if len(v)>1],flags=dict(flags),candidate_count=count,decoding_errors=decode_errors)
 (ROOT/'data/source-audit.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps(summary,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
