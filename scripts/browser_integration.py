#!/usr/bin/env python3
"""Start real local Swift processes, then exercise the UI using the browser test suite."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile
from integration import ready, ROOT

parser=argparse.ArgumentParser()
parser.add_argument('--binary',default='.build/release/pulse')
args=parser.parse_args()
binary=str((ROOT/args.binary).resolve())
processes=[]
with tempfile.TemporaryDirectory(prefix='pulse-browser-') as reports:
    try:
        processes.append(subprocess.Popen([binary,'serve','--port','8080']))
        processes.append(subprocess.Popen([binary,'studio','--port','9090','--reports',reports,'--ui-dir',str(ROOT/'Studio')]))
        ready('http://127.0.0.1:8080/health')
        ready('http://127.0.0.1:9090/api/status')
        subprocess.run(['node','scripts/browser-test.mjs'],cwd=ROOT,check=True,timeout=90)
    finally:
        for process in processes:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:process.wait(timeout=15)
                except subprocess.TimeoutExpired:process.kill();process.wait()
