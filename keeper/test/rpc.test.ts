import { afterEach, describe, expect, it, vi } from "vitest";
import { rpcBatch, rpcRequest } from "../src/rpc";

afterEach(() => vi.unstubAllGlobals());

describe("JSON-RPC transport", () => {
  it("restores batch response order by JSON-RPC id", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(
          JSON.stringify([
            { jsonrpc: "2.0", id: 2, result: "second" },
            { jsonrpc: "2.0", id: 1, result: "first" },
          ]),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      ),
    );
    await expect(
      rpcBatch<string>("https://rpc.example", [
        { method: "first", params: [] },
        { method: "second", params: [] },
      ]),
    ).resolves.toEqual(["first", "second"]);
  });

  it("surfaces JSON-RPC errors without treating them as results", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, error: { code: -32000, message: "reverted" } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
      ),
    );
    await expect(rpcRequest("https://rpc.example", "eth_call", [])).rejects.toMatchObject({
      code: -32000,
      message: "eth_call: reverted",
    });
  });

  it("rejects non-success HTTP responses", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("unavailable", { status: 503 })));
    await expect(rpcRequest("https://rpc.example", "eth_chainId", [])).rejects.toThrow(/HTTP 503/);
  });
});
