import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

// Execute the actual registrations without starting the fixture's HTTP servers.
const source = readFileSync(new URL("./server.js", import.meta.url), "utf8");
const handlers = [...source.matchAll(/socket\.on\("server-socket-id", \(\.\.\.args\) => \{[\s\S]*?\n  \}\);/g)];

test("both namespace handlers safely ignore missing/non-function acks", () => {
  assert.equal(handlers.length, 2);
  for (const [index, match] of handlers.entries()) {
    let handler;
    const socket = { id: `namespace-${index}`, on(event, callback) {
      assert.equal(event, "server-socket-id");
      handler = callback;
    }};
    vm.runInNewContext(match[0], { socket });
    for (const args of [[], [undefined], [null], ["payload"], [{}], [42]]) {
      assert.doesNotThrow(() => handler(...args));
    }
    const replies = [];
    handler(id => replies.push(id));
    handler("optional payload", id => replies.push(id));
    assert.deepEqual(replies, [socket.id, socket.id]);
  }
});
