import Foundation

enum OvernightWorker {
    static let source = #"""
import os, sys, json, time, uuid, pathlib, subprocess, shutil, signal, datetime, urllib.request, urllib.error, math, fcntl, hashlib, threading

DAILY = 100.0 / 7
MARGIN = 1.0  # percentage points; meter updates can lag active requests
POLL = 60
ROOT = pathlib.Path.home() / '.local/state/researchdesk/overnight'

def save(folder, state):
    state['updated'] = time.time()
    temp = folder / 'status.new'
    temp.write_text(json.dumps(state))
    os.replace(temp, folder / 'status.json')

def credentials(retry=True):
    directory = pathlib.Path(os.environ.get('CLAUDE_CONFIG_DIR', str(pathlib.Path.home() / '.claude')))
    blobs = []
    path = directory / '.credentials.json'
    if path.exists(): blobs.append(path.read_text())
    if sys.platform == 'darwin':
        p = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', 'Claude Code-credentials', '-w'], capture_output=True, text=True, timeout=10)
        if p.returncode == 0: blobs.append(p.stdout)
    for blob in blobs:
        try:
            oauth = json.loads(blob).get('claudeAiOauth', {})
            if oauth.get('expiresAt', 0) / 1000 > time.time() + 30 and oauth.get('accessToken'):
                return oauth['accessToken']
        except (ValueError, TypeError): pass
    if retry:
        executable = shutil.which('claude') or str(pathlib.Path.home()/'.local/bin/claude')
        try:
            # Let the installed CLI handle its own login state; never rotate tokens ourselves.
            subprocess.run([executable, 'auth', 'status'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
        except (OSError, subprocess.TimeoutExpired): pass
        return credentials(retry=False)
    raise RuntimeError('Claude subscription login on this machine is missing or expired. Run claude and sign in here, then arm a new night. Credentials are never copied from the Mac.')

def validate_auth(executable):
    overrides = ('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY')
    if any(os.environ.get(key, '').lower() not in ('', '0', 'false') for key in overrides):
        raise RuntimeError('Overnight quota control requires the machine\'s normal Claude subscription login, without API-key, proxy, or cloud-provider overrides.')
    try:
        p = subprocess.run([executable, 'auth', 'status'], capture_output=True, text=True, timeout=10)
        auth = json.loads(p.stdout)
    except (ValueError, OSError, subprocess.TimeoutExpired):
        raise RuntimeError('Could not verify Claude subscription authentication. Update Claude Code and sign in on this machine.')
    method = str(auth.get('authMethod', '')).lower()
    if not auth.get('loggedIn') or auth.get('apiProvider') != 'firstParty' or not method or method == 'none' or 'api' in method:
        raise RuntimeError('Overnight jobs require a Claude subscription login on this machine; API-key billing cannot be measured against the weekly quota.')

def usage():
    request = urllib.request.Request('https://api.anthropic.com/api/oauth/usage', headers={'Authorization': 'Bearer ' + credentials(), 'anthropic-beta': 'oauth-2025-04-20'})
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs): return None
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=15) as response: data = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError('Usage check failed (HTTP %s); no further work will run. Try a new night after checking Claude login/usage.' % error.code)
    def meter(legacy, kind):
        for limit in data.get('limits', []):
            if limit.get('kind') == kind: return float(limit['percent']), limit.get('resets_at')
        item = data.get(legacy)
        if isinstance(item, dict) and item.get('utilization') is not None: return float(item['utilization']), item.get('resets_at')
        raise RuntimeError('Claude did not report both session and weekly quota. Job blocked.')
    weekly, reset = meter('seven_day', 'weekly_all')
    session, session_reset = meter('five_hour', 'session')
    if not reset or not all(math.isfinite(v) and 0 <= v <= 100 for v in (weekly, session)):
        raise RuntimeError('Claude usage reading is incomplete or invalid. Job blocked.')
    reset_at = datetime.datetime.fromisoformat(reset.replace('Z', '+00:00')).timestamp()
    return dict(weekly=weekly, session=session, reset=reset_at)

def ceiling(start, reset, initial):
    # Pace against the account's actual reset, not Monday or the host's timezone.
    elapsed_days = max(0, min(7, (start - (reset - 7 * 86400)) / 86400))
    day_allowance = min(100.0, max(1, math.ceil(elapsed_days)) * DAILY)
    return min(day_allowance, initial + DAILY, 100.0)

def terminate(process):
    if process.poll() is None:
        try: os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError: return
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()

def outputs(path):
    answer, failed, done, partial = '', False, False, False
    try:
        with path.open() as stream:
            for raw in stream:
                try: event = json.loads(raw)
                except ValueError: continue
                if event.get('type') == 'assistant' and not event.get('parent_tool_use_id'):
                    text = '\n'.join(b.get('text', '') for b in event.get('message', {}).get('content', []) if isinstance(b, dict) and b.get('type') == 'text')
                    if text: answer = text
                    if event.get('error'): failed = True
                if event.get('type') == 'result':
                    if event.get('result'): answer = event['result']
                    subtype = str(event.get('subtype', ''))
                    partial = subtype == 'error_max_turns'
                    if event.get('is_error') and subtype != 'error_max_turns':
                        failed = True
                        answer = '\n'.join(event.get('errors', [])) or answer
                    done = 'NO_MORE_WORK' in answer
    except OSError: pass
    return answer, failed, done, partial

def run(folder):
    config = json.loads((folder / 'job.json').read_text())
    state = json.loads((folder / 'status.json').read_text())
    # One account worker at a time, even when armed from different projects.
    lock = (ROOT / 'account.lock').open('a')
    process = None
    watchdog_stop = threading.Event()
    def watchdog():
        while not watchdog_stop.wait(0.5):
            if time.time() >= config['end'] or (folder/'cancel').exists():
                if process is not None: terminate(process)
                return
    watcher = threading.Thread(target=watchdog, daemon=True)
    watcher.start()
    try:
        while time.time() < config['start']:
            if (folder / 'cancel').exists(): state.update(status='cancelled', message='Cancelled before starting.'); return
            time.sleep(min(5, max(0.1, config['start'] - time.time())))
        if time.time() >= config['end']: state.update(status='expired', message='The one-night window has ended.'); return
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if (folder/'cancel').exists(): state.update(status='cancelled', message='Cancelled while waiting.'); return
                if time.time() >= config['end']: state.update(status='expired', message='The overnight window ended while waiting for another job.'); return
                state.update(status='waiting', message='Another overnight job is using this machine account. Waiting for it to finish.'); save(folder, state)
                time.sleep(2)
        validate_auth(config['claude'])
        reading = usage()
        reset = reading['reset']
        target = ceiling(config['start'], reset, reading['weekly'])
        initial = reading['weekly']
        night_key = hashlib.sha256((config.get('zone','')+':'+str(int(config['start']))).encode()).hexdigest()[:20]
        budget_file = ROOT / ('budget-'+night_key+'.json')
        if budget_file.exists():
            budget = json.loads(budget_file.read_text())
            if abs(budget['reset']-reset)>60:
                state.update(status='blocked', message='The quota period changed during this night.'); return
            target = min(target, budget['ceiling'])
        else:
            budget_file.write_text(json.dumps(dict(reset=reset, ceiling=target)))
        state.update(status='running', message='Checking tonight\'s quota.', ceiling=target, stopAt=max(0, target-MARGIN), used=initial, spent=0, sessionUsed=reading['session'])
        save(folder, state)
        checked = time.time()
        batch = 0
        while time.time() < config['end']:
            if (folder / 'cancel').exists(): state.update(status='cancelled', message='Cancelled by you.'); break
            if time.time() - checked >= POLL:
                reading = usage(); checked = time.time()
            if abs(reading['reset'] - reset) > 60:
                state.update(status='blocked', message='Weekly quota reset changed. Arm a new night to use the new period.'); break
            state.update(used=reading['weekly'], spent=max(0, reading['weekly']-initial), sessionUsed=reading['session'])
            if reading['weekly'] >= target - MARGIN:
                state.update(status='budget reached', message='Stopped before tonight\'s ceiling, retaining a 1 percentage-point margin.'); break
            if reading['session'] >= 90:
                state.update(status='waiting', message='Session quota is near its limit. Waiting without running Claude.'); save(folder, state)
                time.sleep(min(5, max(0, config['end']-time.time()))); continue
            batch += 1
            state.update(status='running', message='Working on batch %d.' % batch, batches=batch)
            save(folder, state)
            previous = ''
            reports = sorted(folder.glob('report-*.md'))
            if reports: previous = reports[-1].read_text()[-6000:]
            prompt = ('You are doing one bounded overnight research task. Goal: ' + config['goal'] + '\nUser instructions:\n' + config['instructions'] +
                      '\nWork in this workspace. Read relevant project files. Produce a concise Markdown report with file references and evidence. Do not modify project files or start experiments. Select a small, useful next step different from previous findings. If the goal is exhausted or blocked by unavailable files/services, return NO_MORE_WORK and explain. You have at most 6 tool turns in this batch.\nPrevious batch:\n' + previous)
            transcript = folder / ('batch-%04d.jsonl' % batch)
            with transcript.open('w') as output, (folder / 'claude-errors.log').open('a') as errors:
                process = subprocess.Popen([config['claude'], '-p', '--output-format', 'stream-json', '--verbose', '--permission-mode', 'auto', '--max-turns', '6', '--tools', 'Read,Glob,Grep,WebSearch,WebFetch', '--no-session-persistence', '--model', config['model'], prompt], cwd=config['project'], stdout=output, stderr=errors, stdin=subprocess.DEVNULL, start_new_session=True)
                started = time.time()
                reason = None
                while process.poll() is None:
                    if (folder / 'cancel').exists(): reason = ('cancelled', 'Cancelled by you.'); break
                    if time.time() >= config['end']: reason = ('finished', 'The 7 a.m. deadline has been reached.'); break
                    if time.time()-checked >= POLL:
                        reading = usage(); checked = time.time()
                        state.update(used=reading['weekly'], spent=max(0, reading['weekly']-initial), sessionUsed=reading['session']); save(folder, state)
                        if abs(reading['reset']-reset)>60: reason=('blocked', 'Weekly quota reset changed.'); break
                        if reading['weekly'] >= target-MARGIN: reason=('budget reached', 'Stopped at the conservative quota boundary.'); break
                        if reading['session'] >= 95: reason=('blocked', 'Stopped to preserve session headroom.'); break
                    if time.time()-started >= 180: break
                    time.sleep(1)
                terminate(process)
            answer, failed, done, partial = outputs(transcript)
            if answer: (folder / ('report-%04d.md' % batch)).write_text(answer)
            if reason: state.update(status=reason[0], message=reason[1]); break
            if failed or (not partial and process.returncode not in (0, -signal.SIGTERM)):
                state.update(status='blocked', message=(answer or 'Claude exited unexpectedly. See claude-errors.log on the machine.')[:2000]); break
            if done: state.update(status='complete', message='The agent reports no useful work remains for this goal.'); break
            # Wait before the next batch; always obtain a fresh reading between batches.
            state.update(status='waiting', message='Batch saved. Waiting for the next quota check.'); save(folder, state)
            while time.time()-checked < POLL and time.time() < config['end'] and not (folder/'cancel').exists(): time.sleep(1)
            checked = 0
        else: state.update(status='finished', message='The 7 a.m. deadline has been reached.')
    except Exception as error:
        # No credential payloads or HTTP response bodies are included in status/log output.
        state.update(status='blocked', message=str(error)[:2000])
    finally:
        watchdog_stop.set()
        if process is not None: terminate(process)
        watcher.join(timeout=4)
        save(folder, state)
        lock.close()

def launch(config):
    if abs(time.time()-config['submitted'])>300: raise RuntimeError('The machine clock differs from your Mac by more than five minutes.')
    if config['end'] <= time.time(): raise RuntimeError('This overnight window has already ended.')
    if not os.path.isdir(config['project']): raise RuntimeError('Project directory does not exist on this machine.')
    executable = shutil.which('claude')
    if not executable:
        for path in [pathlib.Path.home()/'.local/bin/claude', pathlib.Path('/opt/homebrew/bin/claude'), pathlib.Path('/usr/local/bin/claude')]:
            if os.access(path, os.X_OK): executable=str(path); break
    if not executable: raise RuntimeError('Claude Code is not installed on this machine.')
    validate_auth(executable)
    reading = usage()  # Preflight before detaching; no model call or work is started here.
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    project_root = ROOT/config['key']
    project_root.mkdir(exist_ok=True, mode=0o700)
    for other in project_root.glob('*/status.json'):
        state = json.loads(other.read_text())
        if state.get('end',0)>time.time() and state.get('status') in ('queued','running','waiting'):
            raise RuntimeError('An overnight job is already armed for this project. Cancel it first.')
    folder = project_root/config['id']
    folder.mkdir(mode=0o700)
    config['claude']=executable
    (folder/'job.json').write_text(json.dumps(config))
    (folder/'worker.py').write_text(SOURCE)
    state=dict(id=config['id'], goal=config['goal'], status='queued', message='Armed for one night only.', start=config['start'], end=config['end'], zone=config['zone'], folder=str(folder), used=reading['weekly'], sessionUsed=reading['session'], batches=0)
    save(folder,state)
    with (folder/'worker.log').open('a') as log:
        p=subprocess.Popen([sys.executable,str(folder/'worker.py'),'run',str(folder)],stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True,close_fds=True)
    # The child owns status after spawn; avoid overwriting a fast child's progress.
    state['pid']=p.pid
    print(json.dumps(state))

if __name__ == '__main__':
    if sys.argv[1]=='run': run(pathlib.Path(sys.argv[2]))
    elif sys.argv[1]=='launch': launch(json.loads(sys.argv[2]))

"""#
}
