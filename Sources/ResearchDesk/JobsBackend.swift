import Foundation

struct DeskJob: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var project: String
    var kind: String
    var submitted: Double
    var status: String
    var command: String?
    var pid: Int?
    var processStart: String?
    var schedulerID: String?
    var conversation: String?
    var scheduled: Double?
    var started: Double?
    var ended: Double?
    var runtime: Double?
    var exitCode: Int?
    var log: String?
    var message: String?
    var checked: Double?
    var terminal: Bool { ["succeeded", "failed", "cancelled"].contains(status) }
    func elapsed(now: Date) -> TimeInterval? {
        if let runtime { return runtime + (status == "running" ? max(0, now.timeIntervalSince1970 - (checked ?? now.timeIntervalSince1970)) : 0) }
        guard let started else { return nil }
        return max(0, (ended ?? (status == "running" ? now.timeIntervalSince1970 : checked ?? started)) - started)
    }
}

struct JobLogChunk: Decodable, Sendable {
    let text: String
    let offset: Int
    let inode: String
    let reset: Bool
}

enum JobsBackend {
    static func invoke(host: String, action: String, payload: [String: Any] = [:]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let command = "python3 -c " + Command.shellQuote(source) + " " + Command.shellQuote(action) + " " + Command.shellQuote(String(decoding: data, as: UTF8.self))
        let result = host.isEmpty
            ? Command.run("/bin/zsh", ["-lc", command], timeout: 25, maxOutput: 2_000_000)
            : Command.ssh(host, command, maxOutput: 2_000_000, timeout: 25)
        guard result.2 == 0 else { throw ResearchError.message(result.1.isEmpty ? "Job host did not respond." : String(result.1.suffix(2000))) }
        return Data(result.0.utf8)
    }
    static func matches(_ job: DeskJob, project: String) -> Bool {
        (job.project as NSString).standardizingPath == (project as NSString).standardizingPath
    }
    static func list(host: String, project: String? = nil) throws -> [DeskJob] {
        try JSONDecoder().decode([DeskJob].self, from: invoke(host: host, action: "list", payload: project.map { ["project": $0] } ?? [:]))
    }
    static func add(project: Project, name: String, kind: String, value: String, log: String, scheduled: Date?) throws -> DeskJob {
        var payload: [String: Any] = ["name": name, "project": project.path, "kind": kind, "log": log]
        if kind == "process" { payload["pid"] = Int(value) }
        else if kind == "slurm" { payload["schedulerID"] = value }
        else { payload["command"] = value; payload["scheduled"] = scheduled?.timeIntervalSince1970 ?? Date().timeIntervalSince1970 }
        return try JSONDecoder().decode(DeskJob.self, from: invoke(host: project.host, action: kind == "shell" ? "launch" : "register", payload: payload))
    }
    static func log(host: String, id: String, offset: Int, inode: String) throws -> JobLogChunk {
        try JSONDecoder().decode(JobLogChunk.self, from: invoke(host: host, action: "log", payload: ["id": id, "offset": offset, "inode": inode]))
    }

    /// Kept in the executable: no separate CLI installation or monitoring daemon.
    static let source = #"""
import os,sys,json,time,pathlib,subprocess,uuid,re,datetime
ROOT=pathlib.Path(os.environ.get('RD_JOBS_ROOT', str(pathlib.Path.home()/'.local/state/researchdesk/jobs')))
TERMINAL={'succeeded','failed','cancelled'}
def save(job):
    ROOT.mkdir(parents=True,exist_ok=True)
    path=ROOT/(job['id']+'.json'); temp=ROOT/(job['id']+'.'+uuid.uuid4().hex+'.tmp')
    temp.write_text(json.dumps(job)); temp.replace(path)
def read(path):
    if path.stat().st_size>65536: raise ValueError('Job record exceeds 64 KB')
    j=json.loads(path.read_text())
    if j.get('version',1)!=1 or not re.fullmatch(r'[A-Za-z0-9_-]{1,100}',str(j.get('id',''))): raise ValueError('Invalid job record')
    for key in ('name','project','kind','status'):
        if not isinstance(j.get(key),str): raise ValueError('Invalid '+key)
    if j['kind'] not in ('shell','process','slurm') or not isinstance(j.get('submitted'),(int,float)): raise ValueError('Invalid job type or submission time')
    if path.stem!=j['id']: raise ValueError('Job id must match filename')
    return j
def run(args):
    try:
        p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=8)
        return p.returncode,p.stdout,p.stderr
    except (OSError,subprocess.TimeoutExpired) as e: return -1,'',str(e)
def identity(pid):
    code,out,err=run(['ps','-p',str(pid),'-o','lstart='])
    return out.strip() if code==0 else ''
def stamp(s):
    try: return datetime.datetime.fromisoformat(s).timestamp()
    except (ValueError,TypeError):
        try: return datetime.datetime.strptime(s,'%a %b %d %H:%M:%S %Y').timestamp()
        except (ValueError,TypeError): return None
def elapsed(s):
    try:
        days,clock=s.split('-',1) if '-' in s else ('0',s)
        parts=[int(x) for x in clock.split(':')]
        return int(days)*86400+sum(x*(60**i) for i,x in enumerate(reversed(parts)))
    except (ValueError,TypeError): return None
def state(s):
    s=s.split()[0].rstrip('+')
    if s in ('PENDING','REQUEUED','REQUEUE_HOLD','CONFIGURING','RESV_DEL_HOLD'): return 'queued'
    if s in ('RUNNING','COMPLETING','STAGE_OUT','SIGNALING'): return 'running'
    if s=='SUSPENDED': return 'paused'
    if s=='COMPLETED': return 'succeeded'
    if s=='CANCELLED': return 'cancelled'
    if s in ('FAILED','TIMEOUT','OUT_OF_MEMORY','NODE_FAIL','BOOT_FAIL','PREEMPTED','DEADLINE','REVOKED'): return 'failed'
    return 'unknown'
def list_jobs(project=None):
    jobs=[]
    for path in ROOT.glob('*.json'):
        try:
            job=read(path)
            if project is None or os.path.normpath(job['project'])==os.path.normpath(project): jobs.append(job)
        except (OSError,ValueError,KeyError): continue
    jobs.sort(key=lambda j:j['submitted'],reverse=True)
    jobs=jobs[:1000]; now=time.time()
    active=[j for j in jobs if j['status'] not in TERMINAL]
    processes=[j for j in active if j['kind'] in ('shell','process')]
    table={}; ps_error=''
    if processes:
        pids=','.join(str(j['pid']) for j in processes if isinstance(j.get('pid'),int) and j['pid']>0)
        code,out,ps_error=run(['ps','-p',pids,'-o','pid=,stat=,lstart=']) if pids else (0,'','')
        if code==0 or (code==1 and not out.strip()):
            for line in out.splitlines():
                parts=line.strip().split(None,2)
                if len(parts)==3 and parts[0].isdigit(): table[int(parts[0])]=(parts[1],parts[2].strip())
        else: table=None
    for j in processes:
        # Worker-owned records are authoritative for completion. Never overwrite them here.
        j['checked']=now
        if j.get('exitFile'):
            try:
                exit_data=json.loads(pathlib.Path(j['exitFile']).read_text())
                j.update(exitCode=int(exit_data['exitCode']),ended=float(exit_data['ended']))
                j['status']='succeeded' if j['exitCode']==0 else 'failed'
                save(j)
                continue
            except (OSError,ValueError,KeyError,TypeError): pass
        if j['status']=='queued' and j.get('scheduled',0)>now: continue
        if j['kind']=='shell' and j['status']=='queued' and not j.get('pid') and now-j.get('scheduled',0)<15: continue
        pid=j.get('pid')
        if table is None: j.update(status='unknown',message='Process check failed: '+ps_error[:300]); continue
        found=table.get(pid)
        if found and 'Z' not in found[0] and j.get('processStart') and ' '.join(found[1].split())==' '.join(j['processStart'].split()):
            j['status']='running'; j['message']='Process identity verified'
            if not j.get('started'): j['started']=stamp(j['processStart'])
        else: j.update(status='unknown',message='Process is absent or identity changed; no exit status is available')
    slurm=[j for j in active if j['kind']=='slurm' and re.fullmatch(r'\d+(?:_\d+)?',str(j.get('schedulerID','')))]
    if slurm:
        ids=','.join(sorted(set(j['schedulerID'] for j in slurm)))
        code,out,err=run(['squeue','--noheader','--jobs',ids,'--format=%i|%T|%M|%S|%r'])
        rows={}
        if code==0:
            for line in out.splitlines():
                parts=line.strip().split('|',4)
                if len(parts)==5: rows[parts[0]]=parts
        missing=[j for j in slurm if j['schedulerID'] not in rows]
        accounting={}; acct_error=''
        if missing:
            code_a,out_a,acct_error=run(['sacct','--noheader','--parsable2','--allocations','--jobs',','.join(sorted(set(j['schedulerID'] for j in missing))),'--format=JobIDRaw,State,Elapsed,Start,End,ExitCode'])
            if code_a==0:
                for line in out_a.splitlines():
                    p=line.strip().split('|')
                    if len(p)>=6: accounting[p[0]]=p
        for j in slurm:
            j['checked']=now; row=rows.get(j['schedulerID']); acct=accounting.get(j['schedulerID'])
            if row:
                j.update(status=state(row[1]),runtime=elapsed(row[2]),message=row[1]+': '+row[4])
                if j['status'] in ('running','paused'): j['started']=stamp(row[3])
            elif acct:
                j.update(status=state(acct[1]),runtime=elapsed(acct[2]),started=stamp(acct[3]),ended=stamp(acct[4]),message=acct[1]+' · exit '+acct[5])
                try: j['exitCode']=int(acct[5].split(':')[0])
                except ValueError: pass
                if j['status'] in TERMINAL: save(j)
            else: j.update(status='unknown',message=('Scheduler status unavailable: '+(err or acct_error))[:500] or 'Job absent from queue and accounting; outcome unknown')
    return jobs

def register(p,launch=False):
    name=str(p.get('name','')).strip(); project=str(p.get('project','')); kind=p.get('kind')
    if not name or not pathlib.Path(project).is_absolute() or kind not in ('process','slurm','shell'): raise ValueError('Provide a name, absolute project path, and supported job kind')
    j=dict(version=1,id=uuid.uuid4().hex,name=name[:300],project=project,kind=kind,submitted=time.time(),status='unknown')
    if p.get('log'):
        log=pathlib.Path(p['log']).expanduser()
        if not log.is_absolute(): log=pathlib.Path(project)/log
        j['log']=str(log)
    if p.get('conversation'): j['conversation']=str(p['conversation'])[:500]
    if kind=='process':
        pid=p.get('pid')
        if not isinstance(pid,int) or pid<=0: raise ValueError('PID must be a positive integer')
        start=identity(pid)
        if not start: raise ValueError('Process is not running on this host')
        j.update(pid=pid,processStart=start,started=stamp(start),status='running')
    elif kind=='slurm':
        sid=str(p.get('schedulerID',''))
        if not re.fullmatch(r'\d+(?:_\d+)?',sid): raise ValueError('Use a numeric Slurm job ID or an individual array task ID')
        j.update(schedulerID=sid,status='unknown',message='Awaiting scheduler check')
    elif launch:
        command=str(p.get('command','')).strip()
        if not command or len(command)>100000: raise ValueError('Provide a command under 100 KB')
        if not pathlib.Path(project).is_dir(): raise ValueError('Project directory does not exist on this host')
        scheduled=float(p.get('scheduled') or time.time())
        j.update(command=command,scheduled=scheduled,status='queued')
        folder=ROOT/j['id']; folder.mkdir(parents=True)
        j['log']=j.get('log') or str(folder/'output.log')
        j['exitFile']=str(folder/'exit.json')
        worker=folder/'worker.py'; worker.write_text(WORKER)
        save(j)
        with open(folder/'worker.log','ab') as diagnostic:
            proc=subprocess.Popen([sys.executable,str(worker),str(ROOT/(j['id']+'.json'))],stdin=subprocess.DEVNULL,stdout=diagnostic,stderr=diagnostic,start_new_session=True,close_fds=True)
        j['workerPID']=proc.pid
        return j
    else: raise ValueError('Shell jobs must be launched')
    save(j); return j

WORKER=r'''
import sys,json,time,os,pathlib,subprocess,uuid
path=pathlib.Path(sys.argv[1]); j=json.loads(path.read_text())
def save():
    temp=path.with_suffix('.'+uuid.uuid4().hex+'.tmp'); temp.write_text(json.dumps(j)); temp.replace(path)
try:
    delay=max(0,j['scheduled']-time.time())
    if delay: time.sleep(delay)
    log=pathlib.Path(j['log']); log.parent.mkdir(parents=True,exist_ok=True)
    with open(log,'ab',buffering=0) as output:
        proc=subprocess.Popen(['/bin/sh','-c',j['command']],cwd=j['project'],stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT)
        try: start=subprocess.run(['ps','-p',str(proc.pid),'-o','lstart='],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=5).stdout.strip()
        except (OSError,subprocess.TimeoutExpired): start=''
        j.update(pid=proc.pid,processStart=start,started=time.time(),status='running'); save()
        code=proc.wait()
    j.update(exitCode=code,ended=time.time(),status='succeeded' if code==0 else 'failed'); save()
except Exception as e:
    j.update(exitCode=-1,ended=time.time(),status='failed',message=str(e)); save()
exit_path=pathlib.Path(j['exitFile']); temp=exit_path.with_suffix('.tmp')
temp.write_text(json.dumps(dict(exitCode=j['exitCode'],ended=j['ended']))); temp.replace(exit_path)
'''

def log_chunk(p):
    jid=str(p.get('id',''))
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,100}',jid): raise ValueError('Invalid job ID')
    j=read(ROOT/(jid+'.json'))
    if not j.get('log'): raise ValueError('No log path registered for this job')
    path=pathlib.Path(j['log'])
    if not path.is_absolute(): path=pathlib.Path(j['project'])/path
    with open(path,'rb') as f:
        stat=os.fstat(f.fileno()); inode=str(stat.st_dev)+':'+str(stat.st_ino)
        offset=int(p.get('offset',-1)); reset=p.get('inode')!=inode or offset<0 or offset>stat.st_size
        if reset: offset=max(0,stat.st_size-65536)
        # Bound transfers even when the writer outpaces polling.
        if stat.st_size-offset>65536: offset=stat.st_size-65536; reset=True
        f.seek(offset); data=f.read(65536)
        return dict(text=data.decode('utf-8','replace'),offset=f.tell(),inode=inode,reset=reset)

if __name__=='__main__':
    try:
        action=sys.argv[1]; payload=json.loads(sys.argv[2]) if len(sys.argv)>2 else {}
        if action=='list': result=list_jobs(payload.get('project'))
        elif action in ('register','launch'): result=register(payload,action=='launch')
        elif action=='log': result=log_chunk(payload)
        else: raise ValueError('Unknown jobs action')
        print(json.dumps(result))
    except Exception as e: print(str(e),file=sys.stderr); sys.exit(1)
"""#
}
