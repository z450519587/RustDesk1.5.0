import json, subprocess, sys, time
API='https://api.github.com/repos/z450519587/RustDesk1.5.0'
def get(p, token=None):
    cmd=['curl','-s','--max-time','45','-H','Accept: application/vnd.github+json']
    if token: cmd+=['-H',f'Authorization: Bearer {token}']
    cmd.append(f'{API}{p}')
    o=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if o.returncode: return None
    try: return json.loads(o.stdout.decode('utf-8','replace'))
    except: return None
tok=subprocess.run(['git','credential','fill'],input=b'protocol=https\nhost=github.com\n\n',
    stdout=subprocess.PIPE,stderr=subprocess.DEVNULL).stdout.decode()
token=[l.split('=',1)[1] for l in tok.splitlines() if l.startswith('password=')][0]
sha=sys.argv[1]
rid=None
for _ in range(60):
    runs=get('/actions/runs?branch=master&per_page=20', token)
    if runs:
        for r in runs.get('workflow_runs',[]):
            if r['name']=='Build Windows EXE' and r['head_sha'].startswith(sha[:8]):
                rid=r['id']; break
        if rid: break
    time.sleep(15)
if not rid:
    print('run not found'); sys.exit(1)
print(f'monitor Build Windows EXE run={rid}', flush=True)
last=None
for _ in range(300):
    run=get(f'/actions/runs/{rid}', token)
    if run:
        jobs=get(f'/actions/runs/{rid}/jobs', token) or {}
        lines=[]
        for j in jobs.get('jobs',[]):
            if j['name'] in ('Dart Static Check','Windows x64 EXE','Publish Release'):
                lines.append(f"{j['name']}: {j['status']}/{j.get('conclusion')}")
                for s in j.get('steps',[]):
                    if s.get('conclusion') not in ('success','skipped',None):
                        lines.append(f"    [{s.get('status')}/{s.get('conclusion')}] {s['name']}")
        sig='|'.join(lines)
        if sig!=last:
            ts=time.strftime('%H:%M:%S')
            for l in lines: print(f'[{ts}] {l}', flush=True)
            last=sig
        if run.get('status')=='completed':
            print(f"\n=== done: {run.get('conclusion')} ===", flush=True)
            sys.exit(0)
    time.sleep(30)
