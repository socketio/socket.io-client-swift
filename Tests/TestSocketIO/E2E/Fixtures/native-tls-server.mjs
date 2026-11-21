import https from 'node:https';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import { Server } from 'socket.io';

// Ephemeral localhost-only fixtures; no key or trust-store installation.
const directory = process.env.NATIVE_TLS_DIR;
if (!directory) throw new Error('NATIVE_TLS_DIR is required');
const certificate = process.env.NATIVE_TLS_EXPIRED === '1' ? 'expired' : 'leaf';
const server = https.createServer({
  key: readFileSync(join(directory, 'leaf.key')),
  cert: readFileSync(join(directory, `${certificate}.pem`)),
  ...(process.env.NATIVE_TLS_CLIENT_AUTH === '1' ? {
    ca: readFileSync(join(directory, 'ca.pem')),
    requestCert: true,
    rejectUnauthorized: true,
  } : {}),
});
const io = new Server(server, { transports: ['polling', 'websocket'] });
io.on('connection', socket => {
  socket.on('echo', (value, ack) => ack(value));
  socket.on('echoTwo', (first, second, ack) => ack(first, second));
});
server.listen(0, () => {
  console.log(`READY port=${server.address().port} secret=0123456789abcdef`);
});
process.on('SIGTERM', () => io.close(() => process.exit(0)));
