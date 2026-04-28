// Tests for opencode-sse-bridge.js
//
// Run with: node tests/opencode-sse-bridge.test.js
// or:       bun tests/opencode-sse-bridge.test.js

"use strict";

const { createServer } = require("http");
const { spawn } = require("child_process");
const { resolve } = require("path");

const BRIDGE_SCRIPT = resolve(__dirname, "..", "opencode-sse-bridge.js");

// Use whichever runtime is running this test
const RUNTIME = process.argv[0];

let passed = 0;
let failed = 0;

function assert(condition, message) {
  if (!condition) {
    throw new Error("Assertion failed: " + message);
  }
}

function assertEqual(actual, expected, message) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      (message || "assertEqual") +
        ": expected " +
        JSON.stringify(expected) +
        ", got " +
        JSON.stringify(actual)
    );
  }
}

// Create a minimal SSE server that sends predefined events then closes
function createSSEServer(events) {
  return new Promise((resolve) => {
    const server = createServer((req, res) => {
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      });

      for (const event of events) {
        res.write("data: " + JSON.stringify(event) + "\n\n");
      }

      // Small delay then close to let the bridge process the events
      setTimeout(() => {
        res.end();
      }, 100);
    });

    server.listen(0, "127.0.0.1", () => {
      resolve(server);
    });
  });
}

// Run the bridge and collect stdout lines
function runBridge(args, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const proc = spawn(RUNTIME, [BRIDGE_SCRIPT, ...args]);
    const lines = [];
    let stderr = "";
    let buf = "";

    proc.stdout.on("data", (chunk) => {
      buf += chunk.toString();
      const parts = buf.split("\n");
      buf = parts.pop();
      for (const line of parts) {
        if (line) lines.push(JSON.parse(line));
      }
    });

    proc.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    const timer = setTimeout(() => {
      proc.kill("SIGTERM");
    }, timeoutMs);

    proc.on("close", (code) => {
      clearTimeout(timer);
      resolve({ lines, stderr, code });
    });

    proc.on("error", reject);
  });
}

async function test(name, fn) {
  try {
    await fn();
    console.log("  PASS: " + name);
    passed++;
  } catch (err) {
    console.log("  FAIL: " + name);
    console.log("    " + err.message);
    failed++;
  }
}

async function runTests() {
  console.log("Running bridge tests with " + RUNTIME + "...\n");

  await test("filters events by type", async () => {
    const events = [
      { type: "session.created", properties: { sessionID: "s1" } },
      { type: "session.diff", properties: { sessionID: "s1", diff: "big" } },
      { type: "message.updated", properties: { sessionID: "s1" } },
    ];
    const server = await createSSEServer(events);
    const port = server.address().port;

    try {
      const { lines } = await runBridge([
        "--url",
        `http://127.0.0.1:${port}/event`,
        "--events",
        "session.created,message.updated",
      ]);

      assertEqual(lines.length, 2, "should forward 2 of 3 events");
      assertEqual(lines[0].type, "session.created");
      assertEqual(lines[1].type, "message.updated");
    } finally {
      server.close();
    }
  });

  await test("strips summary.diffs from session.created", async () => {
    const events = [
      {
        type: "session.created",
        properties: {
          sessionID: "s1",
          info: {
            id: "s1",
            title: "Test",
            summary: {
              additions: 10,
              deletions: 5,
              files: 2,
              diffs: [
                {
                  file: "a.js",
                  patch: "--- a/a.js\n+++ b/a.js\n@@ huge diff @@",
                },
              ],
            },
          },
        },
      },
    ];
    const server = await createSSEServer(events);
    const port = server.address().port;

    try {
      const { lines } = await runBridge([
        "--url",
        `http://127.0.0.1:${port}/event`,
        "--events",
        "session.created",
      ]);

      assertEqual(lines.length, 1);
      const info = lines[0].properties.info;
      // summary should exist but diffs should be stripped
      assert(info.summary, "summary should exist");
      assertEqual(info.summary.additions, 10, "additions preserved");
      assertEqual(info.summary.diffs, undefined, "diffs should be stripped");
    } finally {
      server.close();
    }
  });

  await test("strips summary.diffs from session.updated", async () => {
    const events = [
      {
        type: "session.updated",
        properties: {
          sessionID: "s1",
          info: {
            id: "s1",
            summary: {
              additions: 1,
              diffs: [{ file: "b.js", patch: "large patch" }],
            },
            revert: {
              diff: "revert diff text",
              snapshot: "abc123",
              other: "keep",
            },
          },
        },
      },
    ];
    const server = await createSSEServer(events);
    const port = server.address().port;

    try {
      const { lines } = await runBridge([
        "--url",
        `http://127.0.0.1:${port}/event`,
        "--events",
        "session.updated",
      ]);

      assertEqual(lines.length, 1);
      const info = lines[0].properties.info;
      assertEqual(info.summary.diffs, undefined, "summary.diffs stripped");
      assertEqual(info.summary.additions, 1, "additions preserved");
      assertEqual(info.revert.diff, undefined, "revert.diff stripped");
      assertEqual(info.revert.snapshot, undefined, "revert.snapshot stripped");
      assertEqual(info.revert.other, "keep", "other revert fields preserved");
    } finally {
      server.close();
    }
  });

  await test("strips state.output from completed tool parts", async () => {
    const events = [
      {
        type: "message.part.updated",
        properties: {
          sessionID: "s1",
          part: {
            id: "p1",
            type: "tool",
            tool: "read",
            state: {
              status: "completed",
              title: "Read file.js",
              output: "entire file contents here, very large ...",
              input: { filePath: "/path/file.js", raw: '{"filePath":"/path/file.js"}' },
              metadata: { output: "truncated preview" },
              attachments: [{ url: "data:image/png;base64,verylongdata" }],
            },
          },
        },
      },
    ];
    const server = await createSSEServer(events);
    const port = server.address().port;

    try {
      const { lines } = await runBridge([
        "--url",
        `http://127.0.0.1:${port}/event`,
        "--events",
        "message.part.updated",
      ]);

      assertEqual(lines.length, 1);
      const state = lines[0].properties.part.state;
      assertEqual(state.output, undefined, "output stripped");
      assertEqual(state.attachments, undefined, "attachments stripped");
      assertEqual(state.input.raw, undefined, "input.raw stripped");
      // Preserved fields
      assertEqual(state.status, "completed", "status preserved");
      assertEqual(state.title, "Read file.js", "title preserved");
      assertEqual(state.input.filePath, "/path/file.js", "input.filePath preserved");
      assertEqual(state.metadata.output, "truncated preview", "metadata.output preserved");
    } finally {
      server.close();
    }
  });

  await test("does not strip from pending tool parts (no output)", async () => {
    const events = [
      {
        type: "message.part.updated",
        properties: {
          sessionID: "s1",
          part: {
            id: "p1",
            type: "tool",
            state: {
              status: "pending",
              input: { command: "ls", raw: '{"command":"ls"}' },
            },
          },
        },
      },
    ];
    const server = await createSSEServer(events);
    const port = server.address().port;

    try {
      const { lines } = await runBridge([
        "--url",
        `http://127.0.0.1:${port}/event`,
        "--events",
        "message.part.updated",
      ]);

      assertEqual(lines.length, 1);
      const state = lines[0].properties.part.state;
      assertEqual(state.status, "pending", "status preserved");
      assertEqual(state.input.command, "ls", "input.command preserved");
      assertEqual(state.input.raw, undefined, "input.raw stripped");
    } finally {
      server.close();
    }
  });

  await test("strips summary.diffs from message.updated", async () => {
    const events = [
      {
        type: "message.updated",
        properties: {
          sessionID: "s1",
          info: {
            id: "m1",
            role: "user",
            summary: {
              title: "Edit",
              diffs: [{ file: "c.js", patch: "large diff" }],
            },
          },
        },
      },
    ];
    const server = await createSSEServer(events);
    const port = server.address().port;

    try {
      const { lines } = await runBridge([
        "--url",
        `http://127.0.0.1:${port}/event`,
        "--events",
        "message.updated",
      ]);

      assertEqual(lines.length, 1);
      const info = lines[0].properties.info;
      assertEqual(info.summary.title, "Edit", "title preserved");
      assertEqual(info.summary.diffs, undefined, "diffs stripped");
    } finally {
      server.close();
    }
  });

  await test("passes through events without large fields unchanged", async () => {
    const events = [
      {
        type: "message.part.delta",
        properties: {
          sessionID: "s1",
          messageID: "m1",
          partID: "p1",
          field: "text",
          delta: "hello world",
        },
      },
    ];
    const server = await createSSEServer(events);
    const port = server.address().port;

    try {
      const { lines } = await runBridge([
        "--url",
        `http://127.0.0.1:${port}/event`,
        "--events",
        "message.part.delta",
      ]);

      assertEqual(lines.length, 1);
      assertEqual(lines[0].properties.delta, "hello world");
      assertEqual(lines[0].properties.field, "text");
    } finally {
      server.close();
    }
  });

  await test("handles auth header", async () => {
    let receivedAuth = null;
    const server = await new Promise((resolve) => {
      const s = createServer((req, res) => {
        receivedAuth = req.headers.authorization;
        res.writeHead(200, { "Content-Type": "text/event-stream" });
        res.write(
          'data: {"type":"test.event","properties":{}}\n\n'
        );
        setTimeout(() => res.end(), 50);
      });
      s.listen(0, "127.0.0.1", () => resolve(s));
    });
    const port = server.address().port;

    try {
      await runBridge([
        "--url",
        `http://127.0.0.1:${port}/event`,
        "--events",
        "test.event",
        "--auth",
        "dXNlcjpwYXNz",
      ]);

      assertEqual(
        receivedAuth,
        "Basic dXNlcjpwYXNz",
        "auth header sent"
      );
    } finally {
      server.close();
    }
  });

  await test("exits with error on connection failure", async () => {
    const { code, stderr } = await runBridge([
      "--url",
      "http://127.0.0.1:1/event",
      "--events",
      "test.event",
    ]);

    assert(code !== 0, "should exit with non-zero code");
    assert(stderr.length > 0, "should have stderr output");
  });

  await test("exits with error for missing --url", async () => {
    const { code, stderr } = await runBridge(["--events", "test.event"]);
    assert(code !== 0, "should exit with non-zero code");
    assert(stderr.includes("--url"), "stderr mentions --url");
  });

  await test("exits with error for missing --events", async () => {
    const { code, stderr } = await runBridge([
      "--url",
      "http://localhost:9999/event",
    ]);
    assert(code !== 0, "should exit with non-zero code");
    assert(stderr.includes("--events"), "stderr mentions --events");
  });

  console.log(
    "\n" + (passed + failed) + " tests, " + passed + " passed, " + failed + " failed"
  );
  process.exit(failed > 0 ? 1 : 0);
}

runTests().catch((err) => {
  console.error("Test runner error:", err);
  process.exit(1);
});
