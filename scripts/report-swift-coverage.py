#!/usr/bin/env python3
"""Summarize LLVM coverage for library sources only, never test/helper sources."""
import json
from pathlib import Path
import sys

source = Path(sys.argv[1])
report = json.loads(source.read_text())
files = [f for block in report['data'] for f in block['files']
         if '/Source/SocketIO/' in f['filename']]
if not files:
    raise SystemExit('Coverage export contains no SocketIO library sources')
result = {'scope': 'Source/SocketIO only; this is execution coverage, NOT JS scenario parity', 'sourceFiles': len(files)}
for key in ('lines', 'functions', 'regions', 'branches'):
    count = sum(f['summary'].get(key, {}).get('count', 0) for f in files)
    covered = sum(f['summary'].get(key, {}).get('covered', 0) for f in files)
    result[key] = {'count': count, 'covered': covered, 'percent': 100 * covered / count if count else None}
text = json.dumps(result, indent=2) + '\n'
print(text, end='')
if len(sys.argv) > 2:
    Path(sys.argv[2]).write_text(text)
