import http from 'node:http';

// Raw Engine.IO fixture: hold one request path without introducing Socket.IO
// namespace or manager-connect timeouts. No heartbeat expires during these tests.
const mode = process.env.REQUEST_TIMEOUT_MODE;
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const handshake = !url.searchParams.has('sid');
  res.setHeader('Content-Type', 'text/plain; charset=UTF-8');
  if (handshake) {
    if (mode === 'handshake') return;
    if (mode === 'trickle') {
      res.writeHead(200);
      res.write('0');
      const interval = setInterval(() => res.write(' '), 50);
      res.on('close', () => clearInterval(interval));
      return;
    }
    res.end('0{"sid":"request-timeout","upgrades":[],"pingInterval":300000,"pingTimeout":300000}');
  } else if (req.method === 'POST') {
    req.resume();
    if (mode !== 'post') res.end('ok');
  } else if (mode === 'post') {
    // Keep GETs healthy while the POST stalls, so only the POST can time out.
    const timer = setTimeout(() => res.end('6'), 25);
    res.on('close', () => clearTimeout(timer));
  }
});
server.listen(0, '127.0.0.1', () => {
  console.log(`READY port=${server.address().port} secret=0123456789abcdef`);
});
process.on('SIGTERM', () => {
  server.closeAllConnections();
  server.close(() => process.exit(0));
});
