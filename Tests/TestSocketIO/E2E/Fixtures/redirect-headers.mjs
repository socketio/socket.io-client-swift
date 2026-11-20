import http from 'node:http';

// Redirect fixture: an origin server that redirects polling requests to
// itself (same origin) or to a second server (other port / other host name),
// and a target that echoes the credential headers it received.
const target = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify({
    authorization: req.headers['authorization'] ?? null,
    apiKey: req.headers['x-api-key'] ?? null,
    cookie: req.headers['cookie'] ?? null,
    host: req.headers['host'] ?? null,
  }));
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

target.listen(0, () => {
  origin.listen(0, () => {
    console.log(`READY port=${origin.address().port} secret=0123456789abcdef`);
  });
});
process.on('SIGTERM', () => {
  for (const server of [origin, target]) { server.closeAllConnections(); server.close(); }
  setTimeout(() => process.exit(0), 50);
});
