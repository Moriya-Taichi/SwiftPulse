#!/usr/bin/env python3
"""Exercise the real Swift server and observer; no load package is needed."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
def free_port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def get(url):
    with urllib.request.urlopen(url,timeout=10) as r:return r.read()
def ready(url):
    end=time.monotonic()+15
    while time.monotonic()<end:
        try:get(url);return
        except Exception:time.sleep(.05)
    raise AssertionError(f'Not ready: {url}')
def stop(p):
    if p and p.poll() is None:
        p.send_signal(signal.SIGTERM)
        try:p.wait(timeout=20)
        except subprocess.TimeoutExpired:p.kill();p.wait()

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',default='.build/release/pulse');args=parser.parse_args()
    binary=str((ROOT/args.binary).resolve());port,studio_port=free_port(),free_port();base=f'http://127.0.0.1:{port}';ui=f'http://127.0.0.1:{studio_port}'
    with tempfile.TemporaryDirectory(prefix='pulse-') as tmp,open(Path(tmp)/'process.log','w') as log:
        server=subprocess.Popen([binary,'serve','--port',str(port),'--trace-capacity','64','--timeout','2'],stdout=log,stderr=log);studio=None
        try:
            ready(base+'/health')
            with ThreadPoolExecutor(max_workers=8) as pool:list(pool.map(lambda _:get(base+'/work?delay=20&fanout=4'),range(20)))
            first=json.loads(get(base+'/__pulse/trace'));assert first['nextCursor']>64 and first['droppedEvents']>0
            # Keep recording after the ring is full; correlate ordinary HTTP traffic.
            req=urllib.request.Request(base+'/health',headers={'X-Pulse-Request-ID':'ordinary-client'})
            with urllib.request.urlopen(req) as r:assert r.read()==b'SwiftPulse OK\n'
            delta=json.loads(get(base+f"/__pulse/trace?after={first['nextCursor']}&session={first['sessionID']}"))
            assert any(e['cat']=='request' and e['args']['requestID']=='ordinary-client' for e in delta['traceEvents'])
            assert all(e['sequence']>first['nextCursor'] for e in delta['traceEvents'])
            # Invalid framing is closed, including input split across reads.
            with socket.create_connection(('127.0.0.1',port),timeout=3) as s:
                s.sendall(b'POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\na');assert s.recv(1)==b''
            # Existing buffers can be sent under backpressure without losing bytes.
            body=bytes(range(251))*4000
            connection=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
            connection.request('POST','/echo',body,{'Content-Length':str(len(body))})
            response=connection.getresponse();assert response.status==200 and response.read()==body
            connection.request('HEAD','/health');response=connection.getresponse();assert response.read()==b'' and int(response.getheader('Content-Length'))>0
            connection.close()
            # Incomplete input is bounded by the read deadline.
            with socket.create_connection(('127.0.0.1',port),timeout=4) as s:
                s.sendall(b'GET / HTTP/1.1\r\nHost: ');assert s.recv(1)==b''
            studio=subprocess.Popen([binary,'studio','--port',str(studio_port),'--target',base,'--ui-dir',str(ROOT/'Studio')],stdout=log,stderr=log)
            ready(ui+'/api/status');assert json.loads(get(ui+'/api/status'))['target']==base+'/__pulse/trace'
            assert b'SwiftPulse Studio' in get(ui+'/')
            observed=json.loads(get(ui+'/api/trace'));assert observed['kind']=='swiftpulse.trace'
            for method,path,expected in [('GET','/api/runs',404),('POST','/api/attack',405)]:
                try:urllib.request.urlopen(urllib.request.Request(ui+path,method=method,data=b'{}' if method=='POST' else None));raise AssertionError('Unexpected load endpoint')
                except urllib.error.HTTPError as e:assert e.code==expected
            # A restart resets the clock/cursor domain, even if the old cursor was larger.
            session=observed['sessionID'];cursor=observed['nextCursor'];stop(server)
            server=subprocess.Popen([binary,'serve','--port',str(port),'--trace-capacity','64'],stdout=log,stderr=log);ready(base+'/health')
            reset=json.loads(get(ui+f'/api/trace?after={cursor}&session={session}'));assert reset['sessionID']!=session and reset['traceEvents']
            assert 'attack --url' not in subprocess.check_output([binary,'help'],text=True)
            print(json.dumps({'result':'PASS','ringOverwrite':first['droppedEvents'],'incrementalEvents':len(delta['traceEvents']),'largeEchoBytes':len(body),'studio':'read-only observer','restartCursor':'reset'}))
        except Exception:log.flush();print((Path(tmp)/'process.log').read_text());raise
        finally:stop(studio);stop(server)
if __name__=='__main__':main()
