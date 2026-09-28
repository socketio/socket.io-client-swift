import { Server } from "socket.io";
import http from "node:http";
import crypto from "node:crypto";

const SECRET = crypto.randomBytes(32).toString("hex");

const recoveryWindowMsEnv = Number(process.env.RECOVERY_WINDOW_MS);
const recoveryWindowMs = Number.isFinite(recoveryWindowMsEnv) && recoveryWindowMsEnv > 0
  ? recoveryWindowMsEnv
  : 60_000;

// Also what the server advertises as `maxPayload` in the engine.io handshake.
// Lowering it makes the polling batch limit observable without megabyte payloads.
const maxHttpBufferSizeEnv = Number(process.env.MAX_HTTP_BUFFER_SIZE);
const maxHttpBufferSize = Number.isFinite(maxHttpBufferSizeEnv) && maxHttpBufferSizeEnv > 0
  ? maxHttpBufferSizeEnv
  : 1e6;

const readJson = (req) => new Promise((resolve, reject) => {
  let buf = "";
  req.on("data", (c) => { buf += c; if (buf.length > 1_000_000) reject(new Error("body too large")); });
  req.on("end", () => { try { resolve(buf ? JSON.parse(buf) : {}); } catch (e) { reject(e); } });
  req.on("error", reject);
});

const lastAuthBySid = new Map();
const reservedCountBySid = new Map();
const RESERVED_NAMES = new Set(["connect", "connect_error", "disconnect", "disconnecting"]);
let totalConnections = 0;
// Counts raw socket.io CONNECT frames as observed at the engine.io layer.
// Unlike `totalConnections` (which is per-namespace `io.on("connection")` and
// can dedupe duplicate CONNECTs on the same engine/nsp), this increments for
// every `0<nsp>` frame that traverses the wire. Used by the multi-callback
// auth-provider E2E to assert that two CONNECT packets are actually written.
let connectFrameCount = 0;
let blockNewConnectionsUntil = 0;
let blockNewConnectionsPending = false;
let blockResetTimer = null;
// Query-bearing URL of the most recent engine.io polling request (GET or
// POST). Polling URLs do not reach the packet layer, so the engine.io layer
// is tapped. They also never reach the http.createServer request handler:
// when socket.io attaches to an http.Server, engine.io removes the server's
// existing `request` listeners and re-adds them behind its own check, so
// `/socket.io/*` requests are handled by engine.io and the original handler
// only sees everything else.
let lastPollingUrl = null;

const resetBlockedConnections = () => {
  if (blockResetTimer) {
    clearTimeout(blockResetTimer);
    blockResetTimer = null;
  }
  blockNewConnectionsPending = false;
  blockNewConnectionsUntil = 0;
};

const armBlockedConnectionsUntil = (durationMs) => {
  if (blockResetTimer) {
    clearTimeout(blockResetTimer);
    blockResetTimer = null;
  }

  blockNewConnectionsPending = false;
  blockNewConnectionsUntil = durationMs === 0 ? 0 : Date.now() + durationMs;
  if (durationMs > 0) {
    blockResetTimer = setTimeout(() => {
      blockResetTimer = null;
      blockNewConnectionsUntil = 0;
    }, durationMs);
  }
};

const httpServer = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "127.0.0.1"}`);
  if (!url.pathname.startsWith("/admin/")) { res.writeHead(404).end(); return; }
  if (req.headers["x-admin-secret"] !== SECRET) { res.writeHead(401).end("unauthorized"); return; }
  const host = req.headers.host ?? "";
  if (!/^127\.0\.0\.1:\d+$|^localhost:\d+$/.test(host)) { res.writeHead(403).end("bad host"); return; }

  try {
    if (url.pathname === "/admin/ping") { res.writeHead(200).end("pong"); return; }
    if (url.pathname === "/admin/shutdown") { res.writeHead(200).end("bye"); setTimeout(() => process.exit(0), 10); return; }
    if (url.pathname === "/admin/kill-transport") {
      const sid = url.searchParams.get("sid");
      const s = sid ? io.sockets.sockets.get(sid) : null;
      if (!s) { res.writeHead(404).end("no sid"); return; }
      s.conn.close();
      res.writeHead(200).end("killed"); return;
    }
    if (url.pathname === "/admin/kill-transport-and-block-new-connections") {
      const sid = url.searchParams.get("sid");
      const durationMs = Number(url.searchParams.get("durationMs") ?? "0");
      const s = sid ? io.sockets.sockets.get(sid) : null;
      if (!s) { res.writeHead(404).end("no sid"); return; }
      if (!Number.isFinite(durationMs) || durationMs < 0) {
        res.writeHead(400).end("bad durationMs");
        return;
      }

      resetBlockedConnections();
      blockNewConnectionsPending = true;

      let settled = false;
      let timeout = null;
      const finish = (status, body) => {
        if (settled) return;
        settled = true;
        if (timeout) clearTimeout(timeout);
        res.writeHead(status, { "Content-Type": "application/json" }).end(JSON.stringify(body));
      };
      const cleanupAndFail = (message) => {
        s.off("disconnect", onDisconnect);
        resetBlockedConnections();
        finish(500, { error: message });
      };
      const onDisconnect = () => {
        armBlockedConnectionsUntil(durationMs);
        finish(200, { blockNewConnectionsUntil });
      };

      s.once("disconnect", onDisconnect);
      timeout = setTimeout(() => {
        cleanupAndFail("disconnect timeout");
      }, 4_000);

      try {
        s.conn.close();
      } catch (error) {
        cleanupAndFail(String(error));
      }
      return;
    }
    if (url.pathname === "/admin/kill-transport-and-emit-on-disconnect") {
      const sid = url.searchParams.get("sid");
      const event = url.searchParams.get("event");
      const s = sid ? io.sockets.sockets.get(sid) : null;
      if (!s || !event) { res.writeHead(404).end("no sid"); return; }

      const body = await readJson(req);
      const argsList = Array.isArray(body?.argsList)
        ? body.argsList.filter((args) => Array.isArray(args))
        : [];
      if (argsList.length === 0) { res.writeHead(400).end("no argsList"); return; }

      let settled = false;
      let timeout = null;
      const finish = (status, message) => {
        if (settled) return;
        settled = true;
        if (timeout) clearTimeout(timeout);
        res.writeHead(status).end(message);
      };

      s.once("disconnect", () => {
        for (const args of argsList) {
          io.emit(event, ...args);
        }
        finish(200, "ok");
      });

      timeout = setTimeout(() => {
        finish(500, "disconnect timeout");
      }, 4_000);

      s.conn.close();
      return;
    }
    if (url.pathname === "/admin/emit") {
      const event = url.searchParams.get("event") ?? "msg";
      const body = await readJson(req);
      const args = Array.isArray(body?.args) ? body.args : [];
      const binary = url.searchParams.get("binary") === "true";
      const payload = binary ? args.map((a) => typeof a === "string" && a.startsWith("b64:") ? Buffer.from(a.slice(4), "base64") : a) : args;
      io.emit(event, ...payload);
      res.writeHead(200).end("ok"); return;
    }
    if (url.pathname === "/admin/emit-raw") {
      const sid = url.searchParams.get("sid");
      const event = url.searchParams.get("event") ?? "msg";
      const s = sid ? io.sockets.sockets.get(sid) : null;
      if (!s) { res.writeHead(404).end("no sid"); return; }

      const body = await readJson(req);
      const args = Array.isArray(body?.args) ? body.args : [];
      s.packet({ type: 2, data: [event, ...args] });
      res.writeHead(200).end("ok"); return;
    }
    if (url.pathname === "/admin/socket-live") {
      const sid = url.searchParams.get("sid");
      const live = sid ? io.sockets.sockets.has(sid) : false;
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ live }));
      return;
    }
    if (url.pathname === "/admin/last-auth") {
      const sid = url.searchParams.get("sid");
      const entry = sid ? lastAuthBySid.get(sid) : null;
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ auth: entry ?? null }));
      return;
    }
    if (url.pathname === "/admin/reserved-count") {
      const sid = url.searchParams.get("sid");
      const count = sid ? (reservedCountBySid.get(sid) ?? 0) : -1;
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ count }));
      return;
    }
    if (url.pathname === "/admin/connect-count") {
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ count: totalConnections }));
      return;
    }
    if (url.pathname === "/admin/connect-frame-count") {
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ count: connectFrameCount }));
      return;
    }
    if (url.pathname === "/admin/reset-connect-count") {
      totalConnections = 0;
      connectFrameCount = 0;
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ count: totalConnections }));
      return;
    }
    if (url.pathname === "/admin/last-polling-query") {
      const query = lastPollingUrl ? (lastPollingUrl.split("?")[1] ?? "") : null;
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ query, url: lastPollingUrl }));
      return;
    }
    res.writeHead(404).end("no route");
  } catch (e) {
    res.writeHead(500).end(String(e));
  }
});

// PER_MESSAGE_DEFLATE=1 negotiates permessage-deflate on the WebSocket, as a
// production server with `perMessageDeflate` enabled does; threshold 0 compresses
// every frame, including the upgrade probe.
const perMessageDeflate = process.env.PER_MESSAGE_DEFLATE === "1" ? { threshold: 0 } : false;

const io = new Server(httpServer, {
  maxHttpBufferSize,
  perMessageDeflate,
  allowRequest: (_req, callback) => {
    callback(null, !blockNewConnectionsPending && Date.now() >= blockNewConnectionsUntil);
  },
  connectionStateRecovery: {
    maxDisconnectionDuration: recoveryWindowMs,
    skipMiddlewares: true,
  },
});

// engine.io emits "headers" for every HTTP long-polling request (handshake,
// GET, POST) before responding, with the Node `req`.
io.engine.on("headers", (_headers, req) => {
  if (typeof req.url === "string" && req.url.includes("transport=polling")) {
    lastPollingUrl = req.url;
  }
});

// Tap engine.io raw packets so we can count socket.io CONNECT frames as they
// land on the wire (engine.io packet type 4 = "message"; socket.io CONNECT is
// "0<nsp>" optionally followed by ",<json>"). Independent of per-namespace
// `io.on("connection")` dedup behaviour on a shared engine.
io.engine.on("connection", (rawSocket) => {
  rawSocket.on("packet", (packet) => {
    if (packet.type === "message" &&
        typeof packet.data === "string" &&
        packet.data.startsWith("0")) {
      connectFrameCount += 1;
    }
  });
});

io.on("connection", (socket) => {
  socket.on("hi", () => socket.emit("hi"));
  // Read the receiving namespace's identity, never echo a caller-provided ID.
  socket.on("server-socket-id", (...args) => {
    const ack = args[args.length - 1];
    if (typeof ack === "function") { ack(socket.id); }
  });
  totalConnections += 1;
  lastAuthBySid.set(socket.id, socket.handshake.auth);
  reservedCountBySid.set(socket.id, 0);
  socket.onAny((eventName) => {
    if (RESERVED_NAMES.has(eventName)) {
      reservedCountBySid.set(socket.id, (reservedCountBySid.get(socket.id) ?? 0) + 1);
    }
  });
  socket.on("disconnect", () => {});

  // Phase 6 E2E: echo any "message" event back via socket.send (which on the
  // server side wraps it as a "message" event for the client).
  socket.on("message", (...args) => {
    if (args.length > 0 && typeof args[args.length - 1] === "function") {
      // Last arg is an ack callback — invoke it with "ack:" + first arg.
      const ack = args.pop();
      ack("ack:" + (args[0] ?? ""));
      return;
    }
    socket.send(...args);
  });

  // Phase 9 E2E: ping/pong ack roundtrip for SocketTimedEmitter.
  // Note: this is a socket.io application-level "ping" event and does not
  // collide with engine.io's transport-level ping/pong frames.
  socket.on("ping", (...args) => {
    const cb = args[args.length - 1];
    if (typeof cb === "function") {
      cb("pong");
    }
  });

  // JS parity: `socket.on("false", () => socket.emit("false", false))` from the
  // JS support server. Pins that a JSON `false` survives the round trip.
  socket.on("false", () => {
    socket.emit("false", false);
  });

  // Original client-test direction: the server requests an acknowledgement.
  socket.on("parity-request-ack", () => {
    socket.emit("parity-server-ack", (number, object) => {
      socket.emit("parity-ack-result", number === 5 && object?.test === true);
    });
  });
  socket.on("parity-get-utf8", () => {
    for (const value of ["てすと", "Я Б Г Д Ж Й", "Ä ä Ü ü ß", "utf8 — string", "utf8 — string"]) {
      socket.emit("parity-utf8", value);
    }
  });
  socket.on("parity-binary", (value, ack) => {
    if (typeof ack === "function") ack(value);
  });

  // JS parity: `socket.on("echo", (arg, cb) => cb(arg))` from the JS support
  // server. Used by the ported ack scenarios.
  socket.on("echo", (...args) => {
    const cb = args[args.length - 1];
    if (typeof cb === "function") { cb(args[0]); }
  });

  // JS parity: `socket.on("getHandshake", (cb) => cb(socket.handshake))` from
  // the JS support server. Used by the "query option" scenarios on the default
  // namespace (the custom-namespace ones read `/abc`'s "handshake" event).
  socket.on("getHandshake", (...args) => {
    const cb = args[args.length - 1];
    if (typeof cb === "function") { cb(socket.handshake); }
  });

  // JS parity: the Date fixtures from the JS support server. A Date crosses the
  // wire as the string `JSON.stringify` produces for it, in an event, nested in
  // an object, and through an acknowledgement.
  socket.on("getDate", () => {
    socket.emit("takeDate", new Date());
  });
  socket.on("getDateObj", () => {
    socket.emit("takeDateObj", { date: new Date() });
  });
  socket.on("getAckDate", (...args) => {
    const cb = args[args.length - 1];
    if (typeof cb === "function") { cb(new Date()); }
  });

  // Original connection.ts binary scenarios; acknowledge only if the server
  // decoded native binary data and all surrounding JSON fields survived.
  socket.on("doge", () => socket.emit("doge", Buffer.from("asdfasdf", "utf8")));
  socket.on("getbin", () => socket.emit("takebin", Buffer.from("asdfasdf", "utf8")));
  socket.on("buffa", (value) => {
    if (Buffer.isBuffer(value)) socket.emit("buffack");
  });
  socket.on("jsonbuff", (value) => {
    if (value?.hello === "lol" && Buffer.isBuffer(value.message) && value.goodbye === "gotcha") {
      socket.emit("jsonbuff-ack");
    }
  });

  // JS parity: expect receiving buffers in order (connection.ts
  // "should send events with ArrayBuffers in the correct order"). The flag is
  // per-socket, like the JS support server where it lives in the connection
  // closure. `abuff2-ack` is only emitted if `abuff1` arrived first as binary.
  let receivedAbuff1 = false;
  socket.on("abuff1", (a) => {
    if (Buffer.isBuffer(a)) receivedAbuff1 = true;
  });
  socket.on("abuff2", () => {
    if (receivedAbuff1) socket.emit("abuff2-ack");
  });

  // Phase 9 E2E: intentionally never acks — verifies client-side timeout.
  socket.on("never_ack", () => {
    // intentionally do nothing
  });

  // JS parity (retry.ts "should fail when the server does not acknowledge the
  // packet"): the server receives "ack" without acking it, but announces each
  // receipt as a separate event so the client can count the attempts it made.
  socket.on("ack", () => {
    socket.emit("ack");
  });
});

// Register /admin namespace so AutoConnectE2ETest can verify
// that explicit socket.connect() works for non-default namespaces.
io.of("/admin").on("connection", (socket) => {
  socket.on("disconnect", () => {});
});

// --- socket.io-client (JS) parity fixtures ---------------------------------
// Mirrors packages/socket.io-client/test/support/server.ts so the scenarios
// ported in JSParityE2ETest run against the same server behaviour the JS client
// is tested against. Keep the namespace names and error strings identical.

io.of("/no").use((_socket, next) => {
  next(new Error("Auth failed (custom namespace)"));
});

io.of("/with-data").use((_socket, next) => {
  const err = new Error("Auth failed (with data)");
  err.data = { code: 401, details: "Invalid token" };
  next(err);
});

// Registered so a client can join them; they carry no behaviour of their own.
io.of("/foo").on("connection", (socket) => {
  socket.on("server-socket-id", (...args) => {
    const ack = args[args.length - 1];
    if (typeof ack === "function") { ack(socket.id); }
  });
});
io.of("/asd").on("connection", () => {});
io.of("/valid").on("connection", () => {});

// JS parity: mirrors `server.of("/abc")` in the JS support server — emits the
// handshake (query + auth) so the client can assert on its parameters.
io.of("/abc").on("connection", (socket) => {
  socket.emit("handshake", socket.handshake);
});

httpServer.listen(0, "127.0.0.1", () => {
  const port = httpServer.address().port;
  console.log(`READY port=${port} secret=${SECRET}`);
});
