const fs=require('node:fs'),path=require('node:path'),{spawn}=require('node:child_process');
const {DefaultArtifactClient}=require('@actions/artifact');
const client=new DefaultArtifactClient(),root=process.env.LAB_ACTIONS_PROOF;
const python=process.env.pythonLocation?path.join(process.env.pythonLocation,'bin/python'):'python';
const child=spawn('sudo',['-n','--preserve-env=LAB_ACTIONS_PROOF,LAB_PROBE_APK,ZEUS_ANDROID_IME_APK,NODE_PATH,CHROMIUM_PATH,ANDROID_HOME,ANDROID_SDK_ROOT,PATH,PYTHONPATH,ZEUS_ANDROID_BUILD_UID,ZEUS_ANDROID_TOOL_NETNS',python,'-u','AndroidLab/actions/session.py'],{stdio:'inherit',env:process.env});
let exit=null;child.on('exit',code=>exit=code??1);child.on('error',()=>exit=1);
const published=new Set();let checkpointBytes=0,nextPoll=0,etag='';
const control=path.join(path.dirname(root),'zeus-lab-control');fs.mkdirSync(control,{recursive:true,mode:0o700});
async function pollControl(){
 if(!process.env.GITHUB_TOKEN)return;
 const branch=encodeURIComponent(process.env.GITHUB_REF_NAME),repository=process.env.GITHUB_REPOSITORY;
 const response=await fetch(`https://api.github.com/repos/${repository}/contents/experiments/actions-lab/control.json?ref=${branch}`,{headers:{Authorization:'Bearer '+process.env.GITHUB_TOKEN,Accept:'application/vnd.github+json',...(etag?{'If-None-Match':etag}:{})},redirect:'error',signal:AbortSignal.timeout(10000)});
 if(response.status===304||response.status===404)return;if(!response.ok)throw Error('GitHub control channel HTTP '+response.status);
 etag=response.headers.get('etag')||'';const value=await response.json();if(value.size>256000)throw Error('Encrypted control exceeds limit');
 const data=Buffer.from(value.content,'base64');if(data.length>256000)throw Error('Encrypted control exceeds limit');
 const temporary=path.join(control,'incoming.tmp');fs.writeFileSync(temporary,data,{mode:0o600});fs.renameSync(temporary,path.join(control,'incoming.json'));
}

function files(dir){return fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?files(path.join(dir,e.name)):[path.join(dir,e.name)]);}
(async()=>{
 while(true){
  if(exit===null&&Date.now()>nextPoll){nextPoll=Date.now()+3000;try{await pollControl();}catch(e){console.error(e.message);}}
  for(const name of fs.readdirSync(root).filter(n=>/^ready-\d+\.json$/.test(n)).sort()){
   if(published.has(name))continue;
   const ready=JSON.parse(fs.readFileSync(path.join(root,name),'utf8')),directory=path.resolve(root,ready.directory);
   if(!directory.startsWith(path.resolve(root)+path.sep))throw Error('Invalid checkpoint directory');
   const entries=files(directory),bytes=entries.reduce((n,f)=>n+fs.statSync(f).size,0);
   if(checkpointBytes+bytes>50*1024*1024)throw Error('Test artifact budget reached; session data remains on runner until cleanup');
   if(entries.some(f=>!f.endsWith('.sealed.json')&&!f.endsWith('.zlab')&&!f.endsWith('public-status.json')))throw Error('Refusing an unencrypted Actions artifact');
   const artifact=await client.uploadArtifact(`zeus-lab-${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT}-${ready.sequence}`,entries,directory,{retentionDays:1,compressionLevel:0});
   checkpointBytes+=bytes;console.log(`LAB_ENCRYPTED_CHECKPOINT sequence=${ready.sequence} artifact=${artifact.id} bytes=${bytes}`);published.add(name);
  }
  if(exit!==null&&fs.readdirSync(root).filter(n=>/^ready-\d+\.json$/.test(n)).every(n=>published.has(n)))break;
  await new Promise(r=>setTimeout(r,1000));
 }
 process.exitCode=exit;
})().catch(e=>{console.error(e.message);child.kill('SIGTERM');process.exitCode=1;});
