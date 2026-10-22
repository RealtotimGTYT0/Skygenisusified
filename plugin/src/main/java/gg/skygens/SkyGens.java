package gg.skygens;

import com.google.gson.*;
import org.bukkit.Bukkit;
import org.bukkit.command.*;
import org.bukkit.configuration.file.YamlConfiguration;
import org.bukkit.entity.Player;
import org.bukkit.plugin.java.JavaPlugin;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.io.File;
import java.net.URI;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

public final class SkyGens extends JavaPlugin implements CommandExecutor {
    private HttpClient http;
    private String api, serverId, secret;
    private final Map<String, Integer> pending = new ConcurrentHashMap<>();      // uuid -> unsent seconds
    private final Map<String, String[]> inflight = new ConcurrentHashMap<>();    // uuid -> {key, seconds}
    private final Set<String> applied = ConcurrentHashMap.newKeySet();           // delivery IDs already given
    private File dataFile;
    private final long startMs = System.currentTimeMillis();

    @Override public void onEnable() {
        saveDefaultConfig();
        api = getConfig().getString("api-url", "").replaceAll("/+$", "");
        serverId = getConfig().getString("server-id", "main");
        secret = getConfig().getString("secret", "");
        if (secret.isEmpty() || secret.equals("CHANGE_ME")) { getLogger().severe("Set 'secret' in config.yml"); }
        http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build();
        loadData();
        getCommand("skygens").setExecutor(this);
        var s = Bukkit.getScheduler();
        s.runTaskTimer(this, () -> Bukkit.getOnlinePlayers().forEach(p -> pending.merge(p.getUniqueId().toString(), 1, Integer::sum)), 20L, 20L);
        s.runTaskTimerAsynchronously(this, this::flushPlaytime, 1200L, 1200L);
        s.runTaskTimerAsynchronously(this, this::heartbeat, 100L, 600L);
        s.runTaskTimerAsynchronously(this, this::pollDeliveries, 200L, 300L);
        s.runTaskTimerAsynchronously(this, this::saveData, 600L, 600L);
    }
    @Override public void onDisable() { saveData(); }

    // ---------- persistence (unsent playtime survives restarts/crashes) ----------
    private void loadData() {
        dataFile = new File(getDataFolder(), "data.yml");
        var y = YamlConfiguration.loadConfiguration(dataFile);
        var p = y.getConfigurationSection("pending"); if (p != null) for (var k : p.getKeys(false)) pending.put(k, p.getInt(k));
        var f = y.getConfigurationSection("inflight");
        if (f != null) for (var k : f.getKeys(false)) inflight.put(k, new String[]{f.getString(k + ".key"), f.getString(k + ".seconds")});
        applied.addAll(y.getStringList("applied"));
    }
    private synchronized void saveData() {
        var y = new YamlConfiguration();
        pending.forEach((k, v) -> y.set("pending." + k, v));
        inflight.forEach((k, v) -> { y.set("inflight." + k + ".key", v[0]); y.set("inflight." + k + ".seconds", v[1]); });
        y.set("applied", new ArrayList<>(applied));
        try { y.save(dataFile); } catch (Exception e) { getLogger().warning("save failed: " + e.getMessage()); }
    }

    // ---------- signed HTTP ----------
    private static String hex(byte[] b) { var sb = new StringBuilder(); for (byte x : b) sb.append(String.format("%02x", x)); return sb.toString(); }
    private HttpResponse<String> call(String method, String route, String body, String idemKey) {
        try {
            String path = "/api/plugin/v1" + route, ts = String.valueOf(System.currentTimeMillis()), nonce = UUID.randomUUID().toString();
            body = body == null ? "" : body;
            String bodyHash = hex(MessageDigest.getInstance("SHA-256").digest(body.getBytes(StandardCharsets.UTF_8)));
            Mac mac = Mac.getInstance("HmacSHA256"); mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            String sig = hex(mac.doFinal((method + "\n" + path + "\n" + ts + "\n" + nonce + "\n" + bodyHash).getBytes(StandardCharsets.UTF_8)));
            var b = HttpRequest.newBuilder(URI.create(api + path)).timeout(Duration.ofSeconds(15))
                .header("Content-Type", "application/json").header("X-Server-Id", serverId)
                .header("X-Timestamp", ts).header("X-Nonce", nonce).header("X-Signature", sig);
            if (idemKey != null) b.header("Idempotency-Key", idemKey);
            b.method(method, body.isEmpty() ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body));
            return http.send(b.build(), HttpResponse.BodyHandlers.ofString());
        } catch (Exception e) { getLogger().warning("API " + route + " failed: " + e.getMessage()); return null; }
    }

    // ---------- playtime: stable idempotency key per batch, cleared only after success ----------
    private void flushPlaytime() {
        for (String uuid : new ArrayList<>(pending.keySet())) {
            if (!inflight.containsKey(uuid)) {
                int sec = Math.min(pending.getOrDefault(uuid, 0), 3600);
                if (sec <= 0) continue;
                pending.merge(uuid, -sec, Integer::sum);
                inflight.put(uuid, new String[]{uuid + ":" + UUID.randomUUID(), String.valueOf(sec)});
                saveData();
            }
            var b = inflight.get(uuid);
            var o = new JsonObject(); o.addProperty("mcUuid", uuid); o.addProperty("seconds", Integer.parseInt(b[1]));
            var r = call("POST", "/playtime", o.toString(), b[0]);
            // 200 = applied/replayed; 404 = player not linked yet (drop batch so it doesn't loop forever)
            if (r != null && (r.statusCode() == 200 || r.statusCode() == 404)) { inflight.remove(uuid); saveData(); }
        }
    }
    private void heartbeat() {
        var o = new JsonObject();
        o.addProperty("online", Bukkit.getOnlinePlayers().size()); o.addProperty("max", Bukkit.getMaxPlayers());
        o.addProperty("uptimeSeconds", (System.currentTimeMillis() - startMs) / 1000);
        o.addProperty("tps", Bukkit.getTPS()[0]);
        call("POST", "/heartbeat", o.toString(), null);
    }

    // ---------- deliveries: durable, never applied twice ----------
    private void pollDeliveries() {
        var r = call("GET", "/deliveries/pending", null, null);
        if (r == null || r.statusCode() != 200) return;
        for (JsonElement e : JsonParser.parseString(r.body()).getAsJsonObject().getAsJsonArray("deliveries")) {
            var d = e.getAsJsonObject();
            String id = d.get("deliveryId").getAsString();
            UUID u = UUID.fromString(d.get("mcUuid").getAsString());
            if (applied.contains(id)) { ack(id, "delivered", null); continue; }
            Bukkit.getScheduler().runTask(this, () -> {
                Player p = Bukkit.getPlayer(u);
                if (p == null) return;                                   // stays pending until they join
                if (!applied.add(id)) return;
                saveData();
                var cmds = d.getAsJsonObject("payload").getAsJsonArray("commands");
                if (cmds != null) for (var c : cmds) Bukkit.dispatchCommand(Bukkit.getConsoleSender(), c.getAsString().replace("%player%", p.getName()));
                Bukkit.getScheduler().runTaskAsynchronously(this, () -> ack(id, "delivered", null));
            });
        }
    }
    private void ack(String id, String status, String err) {
        var o = new JsonObject(); o.addProperty("status", status); if (err != null) o.addProperty("error", err);
        call("POST", "/deliveries/" + id + "/ack", o.toString(), "ack:" + id);
    }

    // ---------- /skygens link <code> ----------
    @Override public boolean onCommand(CommandSender s, Command c, String l, String[] a) {
        if (!(s instanceof Player p)) { s.sendMessage("Players only."); return true; }
        if (a.length != 2 || !a[0].equalsIgnoreCase("link")) { p.sendMessage("Usage: /skygens link <code>"); return true; }
        var o = new JsonObject(); o.addProperty("code", a[1]); o.addProperty("mcUuid", p.getUniqueId().toString()); o.addProperty("mcName", p.getName());
        Bukkit.getScheduler().runTaskAsynchronously(this, () -> {
            var r = call("POST", "/link/verify", o.toString(), null);
            p.sendMessage(r != null && r.statusCode() == 200 ? "§aAccount linked!" : "§cLink failed: invalid or expired code.");
        });
        return true;
    }
}
