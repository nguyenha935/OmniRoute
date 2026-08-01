// @ts-nocheck
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const TEST_DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "omniroute-agentrouter-chatcore-"));
process.env.DATA_DIR = TEST_DATA_DIR;

const core = await import("../../src/lib/db/core.ts");
const { handleChatCore } = await import("../../open-sse/handlers/chatCore.ts");

const originalFetch = globalThis.fetch;

function noopLog() {
  return {
    debug() {},
    info() {},
    warn() {},
    error() {},
  };
}

async function waitForAsyncSideEffects() {
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setTimeout(resolve, 20));
}

test.afterEach(async () => {
  globalThis.fetch = originalFetch;
  await waitForAsyncSideEffects();
  core.resetDbInstance();
  fs.rmSync(TEST_DATA_DIR, { recursive: true, force: true });
  fs.mkdirSync(TEST_DATA_DIR, { recursive: true });
});

test.after(() => {
  globalThis.fetch = originalFetch;
  core.resetDbInstance();
  fs.rmSync(TEST_DATA_DIR, { recursive: true, force: true });
});

test("AgentRouter Responses connections send a native Responses body through chatCore", async () => {
  let captured: { url: string; headers: Headers; body: Record<string, unknown> } | null = null;

  globalThis.fetch = async (url, init = {}) => {
    const body = JSON.parse(String(init.body || "{}"));
    captured = {
      url: String(url),
      headers: new Headers(init.headers),
      body,
    };

    if (!("input" in body)) {
      return new Response(JSON.stringify({ error: { message: "input is required" } }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(
      JSON.stringify({
        id: "resp_agentrouter",
        object: "response",
        status: "completed",
        model: "gpt-5.6-sol",
        output: [
          {
            id: "msg_agentrouter",
            type: "message",
            role: "assistant",
            content: [{ type: "output_text", text: "OK", annotations: [] }],
          },
        ],
        usage: { input_tokens: 4, output_tokens: 1, total_tokens: 5 },
      }),
      {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }
    );
  };

  const body = {
    model: "agentrouter/gpt-5.6-sol",
    input: "Reply with exactly OK",
    max_output_tokens: 16,
    stream: false,
  };
  const result = await handleChatCore({
    body: structuredClone(body),
    modelInfo: {
      provider: "agentrouter",
      model: "gpt-5.6-sol",
      extendedContext: false,
    },
    credentials: {
      apiKey: "test-agentrouter-key",
      providerSpecificData: { targetFormat: "openai-responses" },
    },
    log: noopLog(),
    clientRawRequest: {
      endpoint: "/v1/responses",
      body: structuredClone(body),
      headers: new Headers({ accept: "application/json", originator: "codex_cli_rs" }),
    },
    userAgent: "codex_cli_rs/0.146.0",
  });

  assert.equal(result.success, true);
  assert.ok(captured);
  assert.equal(captured.url, "https://agentrouter.org/v1/responses");
  assert.equal(captured.headers.get("authorization"), "Bearer test-agentrouter-key");
  assert.equal(captured.headers.get("originator"), "codex_cli_rs");
  assert.ok("input" in captured.body);
  assert.equal("system" in captured.body, false);
  assert.equal("thinking" in captured.body, false);
  assert.equal("output_config" in captured.body, false);
});

test("AgentRouter OpenAI Chat connections keep the OpenAI request shape through chatCore", async () => {
  let captured: { url: string; headers: Headers; body: Record<string, unknown> } | null = null;

  globalThis.fetch = async (url, init = {}) => {
    captured = {
      url: String(url),
      headers: new Headers(init.headers),
      body: JSON.parse(String(init.body || "{}")),
    };
    return new Response(
      JSON.stringify({
        id: "chatcmpl_agentrouter",
        object: "chat.completion",
        model: "gpt-5.6-sol",
        choices: [
          {
            index: 0,
            message: { role: "assistant", content: "OK" },
            finish_reason: "stop",
          },
        ],
        usage: { prompt_tokens: 4, completion_tokens: 1, total_tokens: 5 },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  };

  const body = {
    model: "agentrouter/gpt-5.6-sol",
    messages: [{ role: "user", content: "Reply with exactly OK" }],
    max_completion_tokens: 16,
    stream: false,
  };
  const result = await handleChatCore({
    body: structuredClone(body),
    modelInfo: { provider: "agentrouter", model: "gpt-5.6-sol", extendedContext: false },
    credentials: {
      apiKey: "test-agentrouter-key",
      providerSpecificData: { targetFormat: "openai" },
    },
    log: noopLog(),
    clientRawRequest: {
      endpoint: "/v1/chat/completions",
      body: structuredClone(body),
      headers: new Headers({ accept: "application/json" }),
    },
    userAgent: "codex_cli_rs/0.146.0",
  });

  assert.equal(result.success, true);
  assert.ok(captured);
  assert.equal(captured.url, "https://agentrouter.org/v1/chat/completions");
  assert.equal(captured.headers.get("authorization"), "Bearer test-agentrouter-key");
  assert.equal(captured.headers.get("originator"), "codex_cli_rs");
  assert.deepEqual(captured.body.messages, body.messages);
  assert.equal(captured.body.max_completion_tokens, 16);
  assert.equal("system" in captured.body, false);
  assert.equal("thinking" in captured.body, false);
  assert.equal("output_config" in captured.body, false);
});

test("AgentRouter default Claude connections retain the Claude Code bridge through chatCore", async () => {
  let captured: { url: string; headers: Headers; body: Record<string, unknown> } | null = null;

  globalThis.fetch = async (url, init = {}) => {
    captured = {
      url: String(url),
      headers: new Headers(init.headers),
      body: JSON.parse(String(init.body || "{}")),
    };
    return new Response(
      [
        "event: message_start",
        'data: {"type":"message_start","message":{"id":"msg_agentrouter","type":"message","role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":4,"output_tokens":0}}}',
        "",
        "event: content_block_delta",
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"OK"}}',
        "",
        "event: message_delta",
        'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}',
        "",
        "event: message_stop",
        'data: {"type":"message_stop"}',
        "",
      ].join("\n"),
      { status: 200, headers: { "Content-Type": "text/event-stream" } }
    );
  };

  const body = {
    model: "agentrouter/claude-opus-4-8",
    messages: [{ role: "user", content: "Reply with exactly OK" }],
    max_tokens: 16,
    stream: false,
  };
  const result = await handleChatCore({
    body: structuredClone(body),
    modelInfo: { provider: "agentrouter", model: "claude-opus-4-8", extendedContext: false },
    credentials: { apiKey: "test-agentrouter-key", providerSpecificData: {} },
    log: noopLog(),
    clientRawRequest: {
      endpoint: "/v1/chat/completions",
      body: structuredClone(body),
      headers: new Headers({ accept: "application/json" }),
    },
    userAgent: "codex_cli_rs/0.146.0",
  });

  assert.equal(result.success, true);
  assert.ok(captured);
  assert.equal(captured.url, "https://agentrouter.org/v1/messages?beta=true");
  assert.equal(captured.headers.get("x-api-key"), "test-agentrouter-key");
  assert.equal(captured.headers.get("authorization"), null);
  assert.ok(Array.isArray(captured.body.messages));
  assert.equal(captured.body.messages[0].role, "user");
  assert.equal(captured.body.thinking.type, "adaptive");
  assert.equal(captured.body.output_config.effort, "xhigh");
});
