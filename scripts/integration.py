#!/usr/bin/env python3
"""Exercise the real Swift CLI/server/Studio API using only Python's standard library."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def get(url):
    with urllib.request.urlopen(url, timeout=10) as response:
        return response.read()

def post(url, payload):
    request = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.read()

def ready(url):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            get(url)
            return
        except Exception:
            time.sleep(.05)
    raise AssertionError(f'Not ready: {url}')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default='.build/release/pulse')
    parser.add_argument('--save-demo', action='store_true')
    args = parser.parse_args()
    binary = str((ROOT / args.binary).resolve())
    server_port, studio_port = free_port(), free_port()
    base = f'http://127.0.0.1:{server_port}'
    studio_url = f'http://127.0.0.1:{studio_port}'
    with tempfile.TemporaryDirectory(prefix='swiftpulse-') as temporary:
        directory = Path(temporary)
        with open(directory/'process.log', 'w') as log:
            server = subprocess.Popen([binary, 'serve', '--port', str(server_port), '--workers', '4'], stdout=log, stderr=log)
            studio = None
            try:
                ready(base+'/health')
                run = directory/'run.json'
                subprocess.run([binary,'attack','--url',base+'/work?delay=20&fanout=4&iterations=200000',
                    '--rate','30','--duration','1s','--trace-url',base+'/__pulse/trace','--output',str(run)],check=True,timeout=30)
                report = json.loads(run.read_text())
                s = report['summary']
                assert s['scheduled'] == 30
                assert s['started'] + s['droppedCapacity'] + s['droppedLate'] == 30
                assert s['completed'] == s['started'] and s['completed'] > 0 and s['failed'] == 0
                events = report['serverTrace']['traceEvents']
                jobs = [e for e in events if e['cat']=='executor' and e['args'].get('requestID','').startswith(report['id']+':')]
                assert jobs and len({e['tid'] for e in jobs}) > 1
                assert all(e['dur'] >= 0 for e in jobs)
                if args.save_demo:
                    # This is real measured output, not a synthesized dashboard fixture.
                    (ROOT/'Studio'/'demo-run.json').write_text(json.dumps(report,separators=(',',':')))
                subprocess.run([binary,'report','--input',str(run)],check=True,timeout=10)
                # Saturation retains the planned rate in counts, rather than turning into closed-loop traffic.
                saturated = directory/'saturated.json'
                subprocess.run([binary,'attack','--url',base+'/work?delay=150','--rate','100','--duration','0.5s',
                    '--concurrency','1','--output',str(saturated)],check=True,timeout=20)
                sat = json.loads(saturated.read_text())['summary']
                assert sat['scheduled']==50 and sat['droppedCapacity']>0 and sat['peakInFlight']==1
                # Cancellation must produce a parseable partial report and release outstanding operations.
                partial=directory/'partial.json'
                attacker=subprocess.Popen([binary,'attack','--url',base+'/work?delay=100','--rate','20','--duration','20s','--output',str(partial)],stdout=log,stderr=log)
                time.sleep(.3);attacker.send_signal(signal.SIGINT);attacker.wait(timeout=15)
                assert attacker.returncode==0 and json.loads(partial.read_text())['summary']['cancelled']
                # A forged conflicting length must never reach the handler or keep the stream reusable.
                with socket.create_connection(('127.0.0.1',server_port),timeout=3) as sock:
                    sock.sendall(b'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\na')
                    assert sock.recv(1)==b''
                studio = subprocess.Popen([binary,'studio','--port',str(studio_port),'--reports',str(directory),'--ui-dir',str(ROOT/'Studio')],stdout=log,stderr=log)
                ready(studio_url+'/api/status')
                assert b'SwiftPulse Studio' in get(studio_url+'/')
                index=json.loads(get(studio_url+'/api/runs'));assert any(r['id']==report['id'] for r in index)
                config=report['configuration'];config['duration']=.2;config['rate']=10;config['traceURL']=None
                new_id=json.loads(post(studio_url+'/api/attack',config))['id']
                deadline=time.monotonic()+15
                while time.monotonic()<deadline:
                    status=json.loads(get(studio_url+'/api/status'))
                    if not status.get('activeID'):break
                    time.sleep(.05)
                result=json.loads(get(studio_url+'/api/runs/'+new_id));assert result['summary']['completed']>0
                print(json.dumps({'result':'PASS','scheduled':s['scheduled'],'completed':s['completed'],'managedJobSlices':len(jobs),
                    'workerLanes':len({e['tid'] for e in jobs}),'saturatedDrops':sat['droppedCapacity'],'studioRun':new_id},indent=2))
            except Exception:
                log.flush()
                print((directory/'process.log').read_text())
                raise
            finally:
                for process in [studio,server]:
                    if process and process.poll() is None:
                        process.send_signal(signal.SIGTERM)
                        try:process.wait(timeout=20)
                        except subprocess.TimeoutExpired:process.kill();process.wait()

if __name__=='__main__':main()
