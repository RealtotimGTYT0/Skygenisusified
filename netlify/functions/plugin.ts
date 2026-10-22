import { createClient } from "@supabase/supabase-js";
import { createHmac, createHash, timingSafeEqual } from "node:crypto";

const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
const json = (s: number, b: unknown) => ({ statusCode: s, headers: { "content-type": "application/json" }, body: JSON.stringify(b) });

export const handler = async (e: any) => {
  const h = (k: string) => e.headers[k] as string | undefined;
  const body = e.body ?? "";
  const path = new URL(e.rawUrl).pathname.replace(/\/+$/, "");
  const ts = Number(h("x-timestamp")), nonce = h("x-nonce"), sig = h("x-signature");
  if (!ts || !nonce || !sig || h("x-server-id") !== process.env.PLUGIN_SERVER_ID) return json(401, { error: "auth" });
  if (Math.abs(Date.now() - ts) > 60_000) return json(401, { error: "stale" });
  const expect = createHmac("sha256", process.env.PLUGIN_SECRET!)
    .update([e.httpMethod, path, ts, nonce, createHash("sha256").update(body).digest("hex")].join("\n")).digest("hex");
  const a = Buffer.from(expect), b = Buffer.from(sig);
  if (a.length !== b.length || !timingSafeEqual(a, b)) return json(401, { error: "bad signature" });
  const n = await db.from("plugin_events").insert({ idempotency_key: "nonce:" + nonce, server_id: h("x-server-id")! });
  if (n.error) return json(401, { error: "replay" });

  const route = path.replace("/api/plugin/v1", "");
  const j = body ? JSON.parse(body) : {};
  const sid = h("x-server-id")!;

  if (route === "/heartbeat") {
    await db.from("server_status").upsert({ id: sid, online: j.online, max_players: j.max, uptime_seconds: j.uptimeSeconds, tps: j.tps, updated_at: new Date().toISOString() });
    return json(200, { ok: true });
  }
  if (route === "/playtime") {
    const idem = h("idempotency-key"); if (!idem || !(j.seconds > 0 && j.seconds <= 3600)) return json(400, { error: "bad request" });
    const { data: p } = await db.from("profiles").select("id").eq("mc_uuid", j.mcUuid).maybeSingle();
    if (!p) return json(404, { error: "not linked" });
    const { data, error } = await db.rpc("apply_playtime", { p_server: sid, p_user: p.id, p_seconds: j.seconds, p_key: idem });
    return error ? json(400, { error: error.message }) : json(200, { reward: data });
  }
  if (route === "/link/verify") {
    const { data } = await db.rpc("link_account", { p_code: j.code, p_uuid: j.mcUuid, p_name: j.mcName });
    return data ? json(200, { ok: true }) : json(400, { error: "invalid" });
  }
  if (route === "/deliveries/pending") {
    const { data } = await db.from("deliveries").select("id,payload,profiles(mc_uuid)").eq("status", "pending").limit(50);
    return json(200, { deliveries: (data ?? []).filter((d: any) => d.profiles?.mc_uuid).map((d: any) => ({ deliveryId: d.id, mcUuid: d.profiles.mc_uuid, payload: d.payload })) });
  }
  const m = route.match(/^\/deliveries\/([0-9a-f-]{36})\/ack$/);
  if (m) {
    await db.from("deliveries").update({ status: j.status === "delivered" ? "delivered" : "failed", delivered_at: new Date().toISOString() }).eq("id", m[1]).eq("status", "pending");
    return json(200, { ok: true });
  }
  return json(404, { error: "unknown route" });
};
