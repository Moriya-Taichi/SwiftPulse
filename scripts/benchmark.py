#!/usr/bin/env python3
"""Alternating, paired localhost comparisons. Traffic generation is external to SwiftPulse.
No claims about other frameworks or production capacity follow from this microbenchmark.
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess
import tempfile
import time
from integration import free_port,ready,stop

async def traffic(port,path,concurrency,each,body=b''):
    latencies=[]
    packet=(f"{'POST' if body else 'GET'} {path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {len(body)}\r\n\r\n").encode()+body
    async def client():
        reader,writer=await asyncio.open_connection('127.0.0.1',port)
        try:
            for _ in range(each):
                start=time.perf_counter();writer.write(packet);await writer.drain()
                header=await reader.readuntil(b'\r\n\r\n');assert header.startswith(b'HTTP/1.1 200 ')
                length=int(next(line.split(b':',1)[1] for line in header.split(b'\r\n') if line.lower().startswith(b'content-length:')))
                data=await reader.readexactly(length)
                if body:assert data==body
                latencies.append((time.perf_counter()-start)*1000)
        finally:
            writer.close()
            # A peer may reset during teardown after every response was consumed.
            # Read/write failures above still propagate and invalidate the run.
            try:await writer.wait_closed()
            except ConnectionResetError:pass
    start=time.perf_counter();await asyncio.wait_for(asyncio.gather(*(client() for _ in range(concurrency))),120)
    elapsed=time.perf_counter()-start
    latencies.sort();return {'requests':len(latencies),'rps':len(latencies)/elapsed,'p99MS':latencies[min(len(latencies)-1,int(len(latencies)*.99))]}

def measure(binary,scenario,requests=200,echo_requests=40,trace_capacity=100000):
    port=free_port();traced=scenario=='traced-health'
    with tempfile.TemporaryFile() as log:
        process=subprocess.Popen([binary,'serve','--port',str(port),'--trace-capacity',str(trace_capacity) if traced else '0'],stdout=log,stderr=log)
        try:
            ready(f'http://127.0.0.1:{port}/health')
            asyncio.run(traffic(port,'/health',4,30))
            # Enough trace capacity to retain all measured requests in both implementations.
            if scenario=='large-echo':result=asyncio.run(traffic(port,'/echo',4,echo_requests,b'a'*524288))
            else:result=asyncio.run(traffic(port,'/health',16,requests))
        except Exception:
            log.seek(0);print(log.read().decode(errors="replace"),flush=True)
            raise
        finally:
            try:os.kill(process.pid,15)
            except ProcessLookupError:pass
            deadline=time.monotonic()+20
            while True:
                pid,status,usage=os.wait4(process.pid,os.WNOHANG)
                if pid:break
                if time.monotonic()>deadline:os.kill(process.pid,9)
                time.sleep(.01)
            process.returncode=os.waitstatus_to_exitcode(status)
    result['serverCPUSeconds']=usage.ru_utime+usage.ru_stime
    result['serverPeakRSSMiB']=usage.ru_maxrss/(1048576 if os.uname().sysname=='Darwin' else 1024)
    return result

def main():
    p=argparse.ArgumentParser();p.add_argument('--before',required=True);p.add_argument('--after',required=True);p.add_argument('--repeats',type=int,default=5);p.add_argument('--output',required=True);p.add_argument('--requests-per-connection',type=int,default=200);p.add_argument('--echo-requests-per-connection',type=int,default=40);p.add_argument('--trace-capacity',type=int,default=100000);a=p.parse_args()
    binaries={'before':str(Path(a.before).resolve()),'after':str(Path(a.after).resolve())};results=[]
    for scenario in ['health','traced-health','large-echo']:
        for repeat in range(a.repeats):
            for name in (['before','after'] if repeat%2==0 else ['after','before']):
                result={'scenario':scenario,'variant':name,'repeat':repeat,**measure(binaries[name],scenario,a.requests_per_connection,a.echo_requests_per_connection,a.trace_capacity)};results.append(result);print(json.dumps(result),flush=True)
    medians={s:{v:{k:statistics.median(r[k] for r in results if r['scenario']==s and r['variant']==v) for k in ['rps','p99MS','serverCPUSeconds','serverPeakRSSMiB']} for v in binaries} for s in ['health','traced-health','large-echo']}
    Path(a.output).write_text(json.dumps({'environment':{'platform':os.uname().sysname,'machine':os.uname().machine,'repeats':a.repeats},'results':results,'medians':medians},indent=2)+'\n')
if __name__=='__main__':main()
