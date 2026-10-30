"""Bounded real-AVD acceptance. Only client-key-encrypted artifacts are published."""
import asyncio,hashlib,json,os,re,secrets,signal,sqlite3,subprocess,tarfile,tempfile,time,urllib.request,uuid
from pathlib import Path
import httpx,uvicorn
from zeus_android.app import create_app
from zeus_android.device import Device
from zeus_android.tokens import encode
from zeus_android.sealed import seal,seal_file

ROOT=Path(os.environ['LAB_ACTIONS_PROOF']).resolve()
LAUNCH=json.loads(Path('experiments/actions-lab/launch.json').read_text())
CLOUDFLARED='https://github.com/cloudflare/cloudflared/releases/download/2026.10.6/cloudflared-linux-amd64'
DIGEST='1d356dac769d0dbf62ebe588c4034824bbff98d5790c2f844cc99e0e2f57462d'


def publish(sequence,directory):
    temp=ROOT/f'ready-{sequence}.tmp';temp.write_text(json.dumps({'sequence':sequence,'directory':directory.name}));temp.chmod(0o644);temp.replace(ROOT/f'ready-{sequence}.json')

def encrypted_json(directory,name,value):
    directory.mkdir(exist_ok=True,mode=0o755)
    directory.chmod(0o755)
    path=directory/(name+'.sealed.json');path.write_text(json.dumps(seal(json.dumps(value).encode(),LAUNCH['public_key'],LAUNCH['session'])));path.chmod(0o644)

def clean_env(extra=None):
    return {**{k:os.environ[k] for k in ('PATH','HOME','LANG','NODE_PATH','CHROMIUM_PATH') if k in os.environ},**(extra or {})}


def checkpoint(data,directory,sequence,final,private):
    output=directory/f'checkpoint-{sequence}';output.mkdir(mode=0o755,exist_ok=True)
    output.chmod(0o755)
    with tempfile.TemporaryDirectory(dir=private) as temporary:
        temp=Path(temporary);db=sqlite3.connect(data/'state.sqlite3');snapshot=sqlite3.connect(temp/'state.sqlite3')
        db.backup(snapshot);snapshot.close();db.close();archive=temp/'checkpoint.tar.gz';total=0
        with tarfile.open(archive,'w:gz') as tar:
            for path in sorted(data.rglob('*')):
                if not path.is_file() or path.is_symlink() or path.name.startswith('state.sqlite3'):continue
                total+=path.stat().st_size
                if total>25*1024*1024:raise ValueError('Acceptance checkpoint exceeds 25MiB plaintext limit')
                tar.add(path,arcname=str(path.relative_to(data)),recursive=False)
            tar.add(temp/'state.sqlite3',arcname='state.sqlite3',recursive=False)
        target=output/'session.zlab';metadata=seal_file(archive,target,LAUNCH['public_key'],LAUNCH['session'],maximum=20*1024*1024);target.chmod(0o644)
        encrypted_json(output,'manifest',{'archive':metadata,'final':final,'checkpoint_time':time.time(),'scope':'this controlled repository fixture session'})
    publish(sequence,output)


async def main():
    os.umask(0o077);ROOT.mkdir(exist_ok=True,mode=0o755)
    for name in ('session','owner','conversation'):uuid.UUID(LAUNCH[name])
    private=ROOT.parent/'zeus-lab-private';private.mkdir(mode=0o711,exist_ok=True);private.chmod(0o711);data=private/'data';data.mkdir(exist_ok=True,mode=0o700)
    stop=asyncio.Event();loop=asyncio.get_running_loop()
    for signum in (signal.SIGTERM,signal.SIGINT):loop.add_signal_handler(signum,stop.set)
    deadline=time.time()+min(900,max(60,int(LAUNCH['runtime_seconds'])))
    bootstrap={'conversation':LAUNCH['conversation'],'viewer':secrets.token_urlsafe(40),'agent':secrets.token_urlsafe(40),'expires':deadline,'url':''}
    key=secrets.token_urlsafe(48);device=Device('emulator-5554');os.environ.update(ZEUS_ANDROID_EXTERNAL_AVD='1',ZEUS_ANDROID_TUNNEL='1')
    app=create_app(root=data,key=key,owner=LAUNCH['owner'],device=device,bootstrap=bootstrap)
    server=uvicorn.Server(uvicorn.Config(app,host='127.0.0.1',port=8088,log_level='error',access_log=False,timeout_graceful_shutdown=5,ws_max_size=16384,ws_max_queue=4))
    serving=asyncio.create_task(server.serve());tunnel=None;log_file=None;result={'session':LAUNCH['session'],'fixture_only':True,'credentials_published_plaintext':False,'status':'preparing'};code=0
    try:
        while not server.started:await asyncio.sleep(.05)
        binary=private/'cloudflared'
        def download():
            with urllib.request.urlopen(CLOUDFLARED,timeout=60) as response:raw=response.read(50*1024*1024)
            if len(raw)!=40275096 or hashlib.sha256(raw).hexdigest()!=DIGEST:raise ValueError('cloudflared verification failed')
            binary.write_bytes(raw);binary.chmod(0o755)
        await asyncio.to_thread(download)
        token=encode(key,LAUNCH['owner'],LAUNCH['conversation'])
        async with httpx.AsyncClient(base_url='http://127.0.0.1:8088',headers={'Authorization':'Bearer '+token},trust_env=False,timeout=120) as client:
            async def call(name,arguments):
                response=await client.post('/v1/tool',json={'name':name,'arguments':arguments,'request_id':str(uuid.uuid4())})
                if response.status_code!=200:raise ValueError('Fixture operation failed: '+str(response.status_code)+' '+response.text[:1000])
                return response.json()
            await call('android_device',{'operation':'start'})
            apk=Path(os.environ['LAB_PROBE_APK']).read_bytes();response=await client.post('/v1/upload',content=apk,headers={'X-Filename':'zeus-ci-probe.apk','Content-Type':'application/vnd.android.package-archive'})
            response.raise_for_status();project=response.json()['id'];result['project']=project
            await call('android_project',{'operation':'install','project':project})
            await call('android_ui',{'operation':'launch','package':'com.zeus.lab.probe'})
            (data/'actual-initial-ui.json').write_text(json.dumps(await call('android_ui',{'operation':'tree'})))
            await call('android_device',{'operation':'record_start','project':project,'kind':'logcat'})
            logfile=private/'tunnel.log';log_file=logfile.open('wb')
            tunnel=subprocess.Popen([str(binary),'tunnel','--no-autoupdate','--url','http://127.0.0.1:8088','--protocol','http2'],stdout=log_file,stderr=log_file,env=clean_env(),start_new_session=True)
            for _ in range(100):
                if tunnel.poll() is not None:raise RuntimeError('Temporary tunnel exited')
                matches=re.findall(r'https://[a-z0-9-]+\.trycloudflare\.com',logfile.read_text(errors='replace'))
                if matches:bootstrap['url']=matches[-1];break
                await asyncio.sleep(.5)
            if not bootstrap['url']:raise RuntimeError('Temporary tunnel URL was not issued')
            access={'url':bootstrap['url']+'/lab/','session':LAUNCH['session'],'owner':LAUNCH['owner'],'conversation':LAUNCH['conversation'],'viewer_bootstrap':bootstrap['viewer'],'agent_bootstrap':bootstrap['agent'],'deadline':deadline,'project':project,'transport':'websocket'}
            encrypted_json(ROOT/'connection','connection',access);publish(0,ROOT/'connection')
            checkpoint(data,ROOT,1,False,private)
            result.update(status='ready',actual_android_api=(await device.command('shell','getprop','ro.build.version.sdk')).decode().strip())
            env=clean_env({'LAB_LIVE_URL':bootstrap['url']+'/lab/','LAB_LIVE_TOKEN':encode(key,LAUNCH['owner'],LAUNCH['conversation']),'LAB_LIVE_PROJECT':project,'LAB_PROOF_DIR':str(data)})
            browser=await asyncio.create_subprocess_exec('node','AndroidLab/actions/tunnel_browser.cjs',env=env,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.STDOUT)
            try:
                async with asyncio.timeout(80):browser_log,_=await browser.communicate()
            except asyncio.TimeoutError:browser.kill();await browser.wait();raise ValueError('Tunnel browser acceptance timed out')
            (data/'browser.log').write_bytes(browser_log)
            result['browser_passed']=browser.returncode==0
            if browser.returncode!=0:result['browser_error']='See encrypted browser.log'
            checkpoint(data,ROOT,2,False,private)
            print('LAB_ACCEPTANCE_READY browser_passed='+str(result['browser_passed']),flush=True)
            while time.time()<deadline and not stop.is_set():
                saved=app.state.lab.load()
                if saved and saved['status']=='stopped':result['ended']='user_stop';break
                try:await asyncio.wait_for(stop.wait(),2)
                except asyncio.TimeoutError:pass
            else:result['ended']='deadline_or_signal'
            result['status']='completed' if result.get('browser_passed') else 'transport_not_verified'
    except BaseException as error:
        code=1;result.update(status='failed',error=type(error).__name__,detail=str(error)[:3000])
    finally:
        (data/'result.json').write_text(json.dumps(result,indent=2))
        server.should_exit=True
        try:await asyncio.wait_for(serving,10)
        except asyncio.TimeoutError:serving.cancel();await asyncio.gather(serving,return_exceptions=True)
        try:checkpoint(data,ROOT,99,True,private)
        except Exception as error:
            encrypted_json(ROOT/'failed-checkpoint','failure',{'error':type(error).__name__,'detail':str(error)[:1000]});publish(98,ROOT/'failed-checkpoint');code=1
        if tunnel and tunnel.poll() is None:
            os.killpg(tunnel.pid,signal.SIGKILL);tunnel.wait()
        if log_file:log_file.close()
        print('LAB_SESSION_ENDED status='+result['status'],flush=True)
    return code

if __name__=='__main__':raise SystemExit(asyncio.run(main()))
