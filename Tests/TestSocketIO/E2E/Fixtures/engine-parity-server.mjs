// Raw Engine.IO fixture: no Socket.IO parser can hide a transport codec defect.
import { createServer } from 'node:http';
import { randomBytes } from 'node:crypto';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
// Resolve the exact Engine.IO dependency of our locked Socket.IO fixture.
const enginePath = require.resolve('engine.io', { paths: [require.resolve('socket.io')] });
const { Server } = require(enginePath);
const secret = randomBytes(16).toString('hex');
const observations = { requests: [], frames: [] };
const http = createServer((req, res) => {
  if (req.url !== '/admin/snapshot' || req.headers['x-admin-secret'] !== secret) {
    res.writeHead(404).end(); return;
  }
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(observations));
});
const engine = new Server({
  transports: ['polling', 'websocket'],
  maxHttpBufferSize: Number(process.env.MAX_HTTP_BUFFER_SIZE || 1000000),
  pingInterval: 25000, pingTimeout: 20000,
  allowRequest: (request, callback) => {
    const transport = new URL(request.url, 'http://localhost').searchParams.get('transport');
    callback(null, transport !== process.env.DENY_TRANSPORT);
  },
});
engine.attach(http, { path: '/engine.io', addTrailingSlash: process.env.NO_TRAILING_SLASH !== '1' });
engine.on('initial_headers', (headers) => {
  headers['set-cookie'] = ['1=1; Path=/', '2=2; Path=/'];
});
const observeFrames = (transport) => {
  if (transport.name !== 'websocket') return;
  transport.socket.on('message', (data, binary) => {
    observations.frames.push({ binary, payload: binary ? data.toString('base64') : data.toString() });
  });
};
engine.on('connection', (socket) => {
  observeFrames(socket.transport);
  socket.on('upgrade', (transport) => {
    observeFrames(transport);
    if (process.env.EMIT_UPGRADE_MARKER === '1') socket.send('__parity_upgraded__');
  });
  if (process.env.SEND_GREETING === '1') socket.send('hi');
  socket.on('message', (data) => socket.send(data));
});
http.prependListener('request', (req) => {
  if (!req.url.startsWith('/engine.io')) return;
  const record = { method: req.method, url: req.url, headers: req.headers, body: '', bytes: 0 };
  observations.requests.push(record);
  // A data listener resumes even an empty GET and emits its normal request-close
  // before the pending poll responds. Observe without changing stream flow.
  const push = req.push;
  req.push = function(chunk, encoding) {
    if (chunk !== null) {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, encoding);
      record.bytes += bytes.length;
      if (record.bytes <= 8192) record.body += bytes.toString();
    }
    return push.call(this, chunk, encoding);
  };
});
http.on('upgrade', (req) => {
  observations.requests.push({ method: 'UPGRADE', url: req.url, headers: req.headers });
});
http.listen(0, '127.0.0.1', () => {
  console.log(`READY port=${http.address().port} secret=${secret}`);
});
process.on('SIGTERM', () => { engine.close(); http.close(() => process.exit(0)); });
