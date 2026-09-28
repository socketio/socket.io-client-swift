// Protocol-level proof for the transport pause in SocketEnginePollable.
//
// Runs against the same real Socket.IO 4.8 server the Swift E2E tests use and
// shows deterministically why the upgrade has to wait for a pending POST:
//
//   Scenario A - the upgrade packet reaches the server before an already sent
//                POST. The server answers that POST with HTTP 400 and the event
//                it carried is never delivered. This is the order an unpatched
//                client can produce.
//   Scenario B - the POST is awaited (drained) and only then is the upgrade
//                sent. The POST succeeds and the event is acknowledged. This is
//                the order engine.io-client (JS) guarantees via pause(), and the
//                order this fork now produces.
//
// Run:      npm install && node upgrade-race-proof.mjs   (in this directory)
// Requires: Node >= 18. No Swift toolchain, so it also runs where Starscream
//           cannot be built.
//
// Exits non-zero unless A loses the event and B delivers it.
//
// This pins the server contract. The client-side invariant is pinned by
// SocketEngineTest.testUpgradeIsDeferredUntilPollAndPostSettled and
// testPendingUpgradeDoesNotMarkTheTransportAsWriting.
import { spawn } from "node:child_process"
import { fileURLToPath } from "node:url"

const server = spawn("node", ["server.js"], {
  cwd: fileURLToPath(new URL(".", import.meta.url)),
})
const port = await new Promise((resolve, reject) => {
  let buf = ""
  const t = setTimeout(() => reject(new Error("server did not start")), 15000)
  server.stdout.on("data", d => {
    buf += d
    const m = buf.match(/READY port=(\d+)/)
    if (m) { clearTimeout(t); resolve(Number(m[1])) }
  })
  server.stderr.on("data", d => process.stderr.write(`[server] ${d}`))
})
const base = `http://127.0.0.1:${port}`

async function session(label, upgradeFirst) {
  // 1) Engine.IO handshake over polling.
  const open = JSON.parse((await (await fetch(`${base}/socket.io/?EIO=4&transport=polling`)).text()).slice(1))
  const sid = open.sid
  const poll = () => fetch(`${base}/socket.io/?EIO=4&transport=polling&sid=${sid}`).then(r => r.text())
  const post = body => fetch(`${base}/socket.io/?EIO=4&transport=polling&sid=${sid}`,
    { method: "POST", body, headers: { "content-type": "text/plain;charset=UTF-8" } })

  // 2) Namespace CONNECT, the way socket.connect() sends it.
  const connectAck = poll()
  await post("40")
  const framed = await connectAck
  if (!framed.includes('40{"sid"')) throw new Error(`no namespace CONNECT: ${framed}`)

  // 3) Open the WebSocket and probe it.
  const ws = new WebSocket(`${base.replace("http", "ws")}/socket.io/?EIO=4&transport=websocket&sid=${sid}`)
  const acks = []
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = () => j(new Error("ws error")) })
  ws.onmessage = e => acks.push(String(e.data))
  ws.send("2probe")
  await new Promise(r => setTimeout(r, 150))
  if (!acks.includes("3probe")) throw new Error(`no 3probe: ${acks}`)

  // 4) The ordering that decides it.
  let status
  if (upgradeFirst) {
    ws.send("5")                                          // upgrade goes first
    await new Promise(r => setTimeout(r, 120))
    status = (await post('420["ping","hello"]')).status   // the POST arrives too late
  } else {
    const p = post('420["ping","hello"]')                 // POST goes first ...
    status = (await p).status                             // ... and is awaited (drain)
    ws.send("5")
  }
  await new Promise(r => setTimeout(r, 400))
  const acked = acks.some(a => a.startsWith("430") && a.includes("pong"))
  console.log(`${label}\n  POST status: ${status}\n  server ack:  ${acked ? "yes" : "no (event lost)"}`)
  ws.close()
  return { status, acked }
}

const a = await session("Scenario A - upgrade packet overtakes the POST (unpatched client)", true)
const b = await session("Scenario B - POST awaited, then upgrade (JS client, and this fork)", false)
server.kill()

const asExpected = a.status === 400 && !a.acked && b.status === 200 && b.acked
console.log(`\nRESULT: ${asExpected
  ? "mechanism confirmed - A loses the event, B delivers it."
  : `unexpected - A=${JSON.stringify(a)} B=${JSON.stringify(b)}`}`)
process.exitCode = asExpected ? 0 : 1
