import http from 'node:http';
import crypto from 'node:crypto';

// Redirect fixture: an origin server that redirects polling requests to
// itself (same origin) or to a second server (other port / other host name),
// and a target that echoes the credential headers, method and body it received.
const target = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({
      authorization: req.headers['authorization'] ?? null,
      apiKey: req.headers['x-api-key'] ?? null,
      cookie: req.headers['cookie'] ?? null,
      host: req.headers['host'] ?? null,
      method: req.method,
      body: Buffer.concat(chunks).toString(),
    }));
  });
});

const origin = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://placeholder');
  const tport = target.address().port;
  const oport = origin.address().port;
  const status = Number(url.searchParams.get('status') ?? '307');
  let location;
  switch (url.pathname) {
    case '/same': location = `http://127.0.0.1:${oport}/echo`; break;
    case '/port': location = `http://127.0.0.1:${tport}/echo`; break;
    case '/host': location = `http://localhost:${tport}/echo`; break;
    case '/echo':
      return target.emit('request', req, res);
    default:
      res.writeHead(404); return res.end();
  }
  res.writeHead(status, { Location: location });
  res.end();
});

// WebSocket handshakes: /ws-same, /ws-port and /ws-host redirect like the HTTP
// paths; /ws-echo accepts and sends one text frame with the received headers.
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
  const tport = target.address().port;
  const oport = origin.address().port;
  const location = {
    '/ws-same': `ws://127.0.0.1:${oport}/ws-echo`,
    '/ws-port': `ws://127.0.0.1:${tport}/ws-echo`,
    '/ws-host': `ws://localhost:${tport}/ws-echo`,
  }[url.pathname];
  if (!location) return acceptWebSocket(req, socket);
  socket.end(`HTTP/1.1 307 Temporary Redirect\r\nLocation: ${location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`);
}
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
