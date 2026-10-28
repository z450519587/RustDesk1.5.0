import json, subprocess, sys, time
RUN_ID = sys.argv[1]
API = 'https://api.github.com/repos/z450519587/RustDesk1.5.0'
def get(p):
    o = subprocess.run(['curl','-s','--max-time','45','-H',
        'Accept: application/vnd.github+json', f'{API}{p}'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if o.returncode: return None
    try: return json.loads(o.stdout.decode('utf-8','replace'))
    except: return None
print(f'监控 run={RUN_ID}', flush=True)
last=None
for _ in range(200):
    run = get(f'/actions/runs/{RUN_ID}')
    if run:
        jobs = get(f'/actions/runs/{RUN_ID}/jobs') or {}
        lines=[]
        for j in jobs.get('jobs',[]):
            lines.append(f"{j['name']}: {j['status']}/{j.get('conclusion')}")
            for s in j.get('steps',[]):
                if s.get('status')!='completed' or 'store config' in s['name']:
                    lines.append(f"    [{s.get('status')}/{s.get('conclusion')}] {s['name']}")
        sig='|'.join(lines)
        if sig!=last:
            ts=time.strftime('%H:%M:%S')
            for l in lines: print(f'[{ts}] {l}', flush=True)
            last=sig
        if run.get('status')=='completed':
            print(f"\n=== 完成: {run.get('conclusion')} ===", flush=True)
            for r in (get('/releases?per_page=2') or []):
                print(f"RELEASE {r['tag_name']}", flush=True)
                for a in r.get('assets',[]):
                    print(f"   {a['name']}  {a['size']} bytes  id={a['id']}", flush=True)
            sys.exit(0)
    time.sleep(30)
