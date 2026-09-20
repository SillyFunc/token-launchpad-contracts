import { getConfig } from "./config";
import { rpcRequest } from "./rpc";
import { KeeperWorkflow } from "./workflow";
import { SignerDurableObject } from "./signer";
import type { Env, KeeperWorkflowPayload } from "./types";

export { KeeperWorkflow, SignerDurableObject };

function secureEqual(left: string, right: string): boolean {
  const length = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < length; index++) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}

function authorized(request: Request, env: Env): boolean {
  const header = request.headers.get("authorization") ?? "";
  const adminToken = env.ADMIN_TOKEN;
  if (!adminToken || adminToken.length < 32) return false;
  return header.startsWith("Bearer ") && secureEqual(header.slice(7), adminToken);
}

async function createWorkflow(env: Env, payload: KeeperWorkflowPayload, id: string) {
  return env.KEEPER_WORKFLOW.create({
    id,
    params: payload,
    retention: { successRetention: "1 day", errorRetention: "3 days" },
  });
}

async function status(env: Env): Promise<Record<string, unknown>> {
  const config = getConfig(env);
  const [runs, transactions, alerts, balanceHex] = await Promise.all([
    env.DB.prepare("SELECT * FROM keeper_runs ORDER BY started_at DESC LIMIT 10").all(),
    env.DB.prepare("SELECT * FROM transactions ORDER BY updated_at DESC LIMIT 20").all(),
    env.DB.prepare("SELECT * FROM alerts WHERE resolved_at IS NULL ORDER BY created_at DESC LIMIT 20").all(),
    rpcRequest<string>(config.readRpcUrl, "eth_getBalance", [config.keeper, "latest"]),
  ]);
  const signer = env.SIGNER.get(env.SIGNER.idFromName(`${config.chainId}:${config.keeper.toLowerCase()}`));
  return {
    chainId: config.chainId,
    coordinator: config.coordinator,
    keeper: config.keeper,
    keeperBalanceWei: BigInt(balanceHex).toString(),
    signer: await signer.status(),
    runs: runs.results,
    transactions: transactions.results,
    alerts: alerts.results,
  };
}

export default {
  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    const config = getConfig(env);
    const payload: KeeperWorkflowPayload = {
      trigger: "cron",
      requestedAt: Math.floor(controller.scheduledTime / 1000),
    };
    const id = `${config.chainId}-cron-${controller.scheduledTime}`;
    ctx.waitUntil(
      createWorkflow(env, payload, id).catch((error) => {
        console.error("Unable to create scheduled keeper workflow", error);
      }),
    );
  },

  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return Response.json({ ok: true, service: "sillyfunc-launchpad-keeper", time: new Date().toISOString() });
    }
    if (!authorized(request, env)) return Response.json({ error: "unauthorized" }, { status: 401 });

    if (request.method === "GET" && url.pathname === "/admin/status") {
      return Response.json(await status(env));
    }
    if (request.method === "POST" && url.pathname === "/admin/run") {
      const config = getConfig(env);
      const requestedAt = Math.floor(Date.now() / 1000);
      const instance = await createWorkflow(
        env,
        { trigger: "manual", requestedAt },
        `${config.chainId}-manual-${requestedAt}-${crypto.randomUUID().slice(0, 8)}`,
      );
      return Response.json({ id: instance.id }, { status: 202 });
    }
    return Response.json({ error: "not found" }, { status: 404 });
  },
} satisfies ExportedHandler<Env>;
