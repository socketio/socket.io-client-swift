import http from 'node:http';
import crypto from 'node:crypto';

// Redirect fixture: two servers (origin and target, on different ports) that
// redirect requests to themselves (same origin), to each other (other port) or
// to `localhost` (other host name), and echo the credential headers, method
// and body a request finally arrives with.
//
// Redirect paths, on both servers:
//   /same   -> http://127.0.0.1:<origin>/echo
//   /port   -> http://127.0.0.1:<target>/echo
//   /host   -> http://localhost:<target>/echo
//   /bounce -> http://127.0.0.1:<target>/back -> http://127.0.0.1:<origin>/echo (A -> B -> A)
// `?status=` picks the redirect status (default 307); every `?set=` value is
// sent as a Set-Cookie header of the redirect response.
// /eio/ answers an Engine.IO polling handshake and redirects its WebSocket handshake.
let origin;
let target;
const ports = () => ({ o: origin.address().port, t: target.address().port });

function echo(req, res) {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({
      authorization: req.headers['authorization'] ?? null,
      proxyAuthorization: req.headers['proxy-authorization'] ?? null,
      apiKey: req.headers['x-api-key'] ?? null,
      cookie: req.headers['cookie'] ?? null,
      host: req.headers['host'] ?? null,
      method: req.method,
      body: Buffer.concat(chunks).toString(),
    }));
  });
}

// A minimal Engine.IO v4 polling server: enough for a client to open.
function engineIO(req, res, url) {
  if (req.method === 'POST') {
    req.resume();
    return req.on('end', () => res.end('ok'));
  }
  if (url.searchParams.has('sid')) return; // a held long poll
  res.setHeader('Content-Type', 'text/plain; charset=UTF-8');
  res.end('0' + JSON.stringify({
    sid: 'redirected-handshake', upgrades: [], pingInterval: 25000, pingTimeout: 20000, maxPayload: 1000000,
  }));
}

function handle(req, res) {
  const url = new URL(req.url, 'http://placeholder');
  const { o, t } = ports();
  const location = {
    '/same': `http://127.0.0.1:${o}/echo`,
    '/port': `http://127.0.0.1:${t}/echo`,
    '/host': `http://localhost:${t}/echo`,
    '/bounce': `http://127.0.0.1:${t}/back`,
    '/back': `http://127.0.0.1:${o}/echo`,
  }[url.pathname];
  if (url.pathname === '/eio/') return engineIO(req, res, url);
  if (!location) return echo(req, res);
  req.resume();
  const headers = { Location: location, 'Content-Length': '0' };
  const cookies = url.searchParams.getAll('set');
  if (cookies.length > 0) headers['Set-Cookie'] = cookies;
  res.writeHead(Number(url.searchParams.get('status') ?? '307'), headers);
  res.end();
}

// WebSocket handshakes: /ws-same, /ws-port, /ws-host and /eio/ redirect like
// the HTTP paths; /ws-echo accepts and sends one text frame with the received headers.
function echoFrame(req) {
  const payload = Buffer.from(JSON.stringify({
    cookie: req.headers['cookie'] ?? null, host: req.headers['host'] ?? null,
  }));
  return Buffer.concat([Buffer.from([0x81, payload.length]), payload]);
}
function acceptWebSocket(req, socket) {
  const key = req.headers['sec-websocket-key'];
  const accept = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.on('error', () => {});
  socket.on('data', () => {});
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket.write(echoFrame(req));
}
function upgrade(req, socket) {
  socket.on('error', () => {});
  const url = new URL(req.url, 'http://placeholder');
  const { o, t } = ports();
  const location = {
    '/ws-same': `ws://127.0.0.1:${o}/ws-echo`,
    '/ws-port': `ws://127.0.0.1:${t}/ws-echo`,
    '/ws-host': `ws://localhost:${t}/ws-echo`,
    '/eio/': `ws://127.0.0.1:${o}/ws-echo`,
  }[url.pathname];
  if (!location) return acceptWebSocket(req, socket);
  socket.end(`HTTP/1.1 307 Temporary Redirect\r\nLocation: ${location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`);
}

origin = http.createServer(handle);
target = http.createServer(handle);
origin.on('upgrade', upgrade);
target.on('upgrade', upgrade);

target.listen(0, () => {
  origin.listen(0, () => {
    console.log(`READY port=${origin.address().port} secret=0123456789abcdef`);
  });
});
process.on('SIGTERM', () => {
  for (const server of [origin, target]) { server.closeAllConnections(); server.close(); }
  setTimeout(() => process.exit(0), 50);
});
