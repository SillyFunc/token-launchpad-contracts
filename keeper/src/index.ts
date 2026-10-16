import { getConfig } from "./config";
import { KeeperWorkflow } from "./workflow";
import { SignerDurableObject } from "./signer";
import type { Env, KeeperWorkflowPayload } from "./types";

export { KeeperWorkflow, SignerDurableObject };

async function createWorkflow(env: Env, payload: KeeperWorkflowPayload, id: string) {
  return env.KEEPER_WORKFLOW.create({
    id,
    params: payload,
    retention: { successRetention: "1 day", errorRetention: "3 days" },
  });
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

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return Response.json({ ok: true, service: "sillyfunc-launchpad-keeper", time: new Date().toISOString() });
    }
    // No management endpoints: the Worker exposes only the health check. Runs are triggered by Cron.
    return Response.json({ error: "not found" }, { status: 404 });
  },
} satisfies ExportedHandler<Env>;
