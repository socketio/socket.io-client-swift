import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';

// This must fail if the observer resumes GET bodies. Engine.IO treats their
// premature request-close event as a closed polling connection.
test('raw polling observer does not consume requests or close a held poll', { timeout: 10000 }, async () => {
  const child = spawn(process.execPath, ['engine-parity-server.mjs'], {
    cwd: new URL('.', import.meta.url), stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stderr.resume();
  try {
    const ready = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('fixture readiness timeout')), 3000);
      let text = '';
      child.once('error', reject);
      child.stdout.on('data', data => {
        text = (text + data).slice(-4096);
        const match = text.match(/READY port=(\d+) secret=(\w+)/);
        if (match) { clearTimeout(timer); resolve(match); }
      });
    });
    const base = `http://127.0.0.1:${ready[1]}`;
    const request = (url, options = {}) => fetch(url, { ...options, signal: AbortSignal.timeout(3000) });
    const opened = await request(base + '/engine.io/?EIO=4&transport=polling');
    const handshake = await opened.text();
    assert.equal(handshake[0], '0');
    const sid = JSON.parse(handshake.slice(1)).sid;
    const url = `${base}/engine.io/?EIO=4&transport=polling&sid=${sid}`;
    const heldPoll = request(url).then(response => response.text());
    const posted = await request(url, { method: 'POST', body: '4probe', headers: { 'Content-Type': 'text/plain;charset=UTF-8' } });
    assert.equal(posted.status, 200);
    assert.equal(await posted.text(), 'ok');
    assert.equal(await heldPoll, '4probe');
    const snapshot = await request(base + '/admin/snapshot', { headers: { 'X-Admin-Secret': ready[2] } });
    const requests = (await snapshot.json()).requests;
    const post = requests.find(r => r.method === 'POST');
    assert.equal(post.bytes, 6);
    assert.equal(post.body, '4probe');
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit');
      child.kill('SIGTERM');
      const kill = setTimeout(() => child.kill('SIGKILL'), 1000);
      try { await exited; } finally { clearTimeout(kill); }
    }
  }
});
