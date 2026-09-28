// Protocol-level proof for the polling batch limit in SocketEnginePollable.
//
// engine.io v4 servers advertise a `maxPayload` in the handshake. It is not
// advice: a POST above it is answered with HTTP 413 and every packet it carried
// is discarded. No acknowledgements for those events should be observed.
//
//   Scenario A - all queued packets go out in one POST, the way a client that
//                ignores `maxPayload` batches them. HTTP 413, no acks, events
//                gone.
//   Scenario B - the batch is cut at `maxPayload` and the rest follows in the
//                next POST, which is what `getWritablePackets()` in
//                engine.io-client does, and what this fork now does.
//
// Run:      npm install && node max-payload-proof.mjs   (in this directory)
// Requires: Node >= 18. No Swift toolchain.
//
// Exits non-zero unless A loses the events and B delivers them.
//
// This pins the server contract. The client-side invariant is pinned by the
// SocketEngineTest.testPostBatch* cases.
import { spawn } from "node:child_process"
import { fileURLToPath } from "node:url"
import { observePolling } from "./polling-proof-observer.mjs"

const MAX_PAYLOAD = 200
const SEP = String.fromCharCode(30) // the engine.io v4 record separator

const server = spawn("node", ["server.js"], {
  cwd: fileURLToPath(new URL(".", import.meta.url)),
  env: { ...process.env, MAX_HTTP_BUFFER_SIZE: String(MAX_PAYLOAD) },
})
try {
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

  // Two acked events that fit individually but not together.
  const packets = [
    `420["ping","${"a".repeat(120)}"]`,
    `421["ping","${"b".repeat(120)}"]`,
  ]

  /** Exercise one new Engine.IO session with a single or size-bounded POST batch. */
  async function session(label, batchEverything) {
    const open = JSON.parse((await (await fetch(`${base}/socket.io/?EIO=4&transport=polling`)).text()).slice(1))
    const sid = open.sid
    if (open.maxPayload !== MAX_PAYLOAD) {
      throw new Error(`server advertised maxPayload=${open.maxPayload}, expected ${MAX_PAYLOAD}`)
    }
    const poll = signal => fetch(`${base}/socket.io/?EIO=4&transport=polling&sid=${sid}`, { signal })
    const post = body => fetch(`${base}/socket.io/?EIO=4&transport=polling&sid=${sid}`,
      { method: "POST", body, headers: { "content-type": "text/plain;charset=UTF-8" } })

    const [connectAck, connectStatus] = await Promise.all([
      observePolling(poll, frames => frames.some(frame => frame.includes('40{"sid"')), 5000),
      post("40").then(async response => { await response.text(); return response.status }),
    ])
    if (connectStatus !== 200 || !connectAck.frames.some(frame => frame.includes('40{"sid"'))) {
      throw new Error("no namespace CONNECT")
    }

    const statuses = []
    if (batchEverything) {
      const response = await post(packets.join(SEP))
      statuses.push(response.status)
      await response.text()
    } else {
      // Cut at maxPayload: each packet on its own stays under the limit.
      for (const packet of packets) {
        const response = await post(packet)
        statuses.push(response.status)
        await response.text()
      }
    }

    // Never launch a second GET while a timed-out first GET is still active.
    const { frames } = await observePolling(poll,
      received => ["430", "431"].every(id => received.some(frame => frame.includes(id))))
    const joined = frames.join("")
    const acked = ["430", "431"].filter(id => joined.includes(id)).length

    console.log(`${label}\n  POST status: ${statuses.join(", ")}\n  events acked: ${acked} of ${packets.length}`)
    return { statuses, acked }
  }

  const a = await session(`Scenario A - one POST of ${packets.join(SEP).length} bytes, limit is ${MAX_PAYLOAD} (client ignoring maxPayload)`, true)
  const b = await session("Scenario B - batch cut at maxPayload, rest in the next POST (JS client, and this fork)", false)

  const asExpected =
    a.statuses.every(s => s === 413) && a.acked === 0 &&
    b.statuses.every(s => s === 200) && b.acked === packets.length
  console.log(`\nRESULT: ${asExpected
    ? "mechanism confirmed - A loses both events to a 413, B delivers them."
    : `unexpected - A=${JSON.stringify(a)} B=${JSON.stringify(b)}`}`)
  process.exitCode = asExpected ? 0 : 1

} finally {
  // Failure paths must not leave the fixture process alive.
  server.kill()
}
