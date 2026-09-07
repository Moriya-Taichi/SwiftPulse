#!/usr/bin/env python3
"""Verify PulseLoad against a Python HTTP server, independently of SwiftPulse."""
import argparse
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
import json
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time
ROOT=Path(__file__).resolve().parents[1]
class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):pass
    def do_GET(self):
        if self.path=='/slow':time.sleep(.15)
        body=b'x'*(262144 if self.path=='/large' else 2)
        self.send_response(503 if self.path=='/error' else 302 if self.path=='/redirect' else 200)
        if self.path=='/redirect':self.send_header('Location','/error')
        self.send_header('Content-Length',str(len(body)));self.end_headers()
        try:self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError):pass
    def do_POST(self):
        body=self.rfile.read(int(self.headers['Content-Length']))
        assert body==b'hello'
        self.do_GET()
    def handle(self):
        try:super().handle()
        except (BrokenPipeError,ConnectionResetError):pass

def main():
    p=argparse.ArgumentParser();p.add_argument('--binary',default='.build/release/pulse-load');args=p.parse_args();binary=str((ROOT/args.binary).resolve())
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start();base=f'http://127.0.0.1:{server.server_port}'
    try:
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            def run(path,extra=()):
                output=root/(path.strip('/')+'.json')
                subprocess.run([binary,'attack','--url',base+path,'--rate','30','--duration','1s','--output',str(output),*extra],check=True,timeout=30,capture_output=True)
                return json.loads(output.read_text())
            normal=run('/normal');assert normal['summary']['scheduled']==30 and normal['summary']['completed']==30 and normal['summary']['failed']==0
            sat=run('/slow',['--concurrency','1','--max-samples','2']);s=sat['summary'];assert s['droppedCapacity']>0 and s['peakInFlight']==1 and s['started']+s['droppedCapacity']+s['droppedLate']==30 and len(sat['requests'])<=2
            large=run('/large',['--max-response-bytes','1024']);assert large['summary']['failed']==large['summary']['completed'] and large['requests'][0]['error']=='response_body_limit'
            failure=run('/error');assert failure['summary']['failed']==failure['summary']['completed']
            redirect=run('/redirect');assert redirect['summary']['statuses']=={'302':30}
            body=root/'body';body.write_text('hello');run('/post',['--method','POST','--body',str(body)])
            partial=root/'partial.json';process=subprocess.Popen([binary,'attack','--url',base+'/slow','--duration','20s','--output',str(partial)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
            time.sleep(.3);process.send_signal(signal.SIGINT);process.wait(timeout=15);assert process.returncode==0 and json.loads(partial.read_text())['summary']['cancelled']
            subprocess.run([binary,'report','--input',str(root/'normal.json')],check=True,capture_output=True)
            result=subprocess.check_output([binary,'compare','--input',str(root/'normal.json'),'--baseline',str(root/'normal.json')],text=True);assert '+0.00%' in result
            print(json.dumps({'result':'PASS','target':'Python HTTP server','normalCompleted':30,'saturationDrops':s['droppedCapacity'],'bodyLimit':True,'redirectFollowed':False,'cancelled':True,'comparison':True}))
    finally:server.shutdown();server.server_close()
if __name__=='__main__':main()
