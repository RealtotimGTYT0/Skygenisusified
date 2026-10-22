import { useEffect, useState } from "react";
import { createClient } from "@supabase/supabase-js";
const sb = createClient(import.meta.env.VITE_SUPABASE_URL, import.meta.env.VITE_SUPABASE_ANON_KEY);
type Status = { online: number; max_players: number; updated_at: string };
type Row = { website_username: string; minecraft_username: string | null; total_seconds: number };
const STALE_MS = 2 * 60_000;

export default function App() {
  const [st, setSt] = useState<Status | null>(null);
  const [rows, setRows] = useState<Row[] | null>(null);
  useEffect(() => {
    const load = async () => {
      const s = await sb.from("server_status").select("*").limit(1).maybeSingle();
      setSt(s.data as Status | null);
      const l = await sb.from("leaderboard_playtime").select("*");
      setRows((l.data as Row[]) ?? []);
    };
    load(); const t = setInterval(load, 30_000); return () => clearInterval(t);
  }, []);
  const live = st && Date.now() - new Date(st.updated_at).getTime() < STALE_MS;
  return (<>
    <header><b>SkyGens</b><span className="mut">play.skygens.example</span></header>
    <div className="wrap">
      <h1>Sky Generators</h1>
      <div className="card"><h2>Server</h2>
        {!st ? <span className="badge off">Unavailable</span> : live
          ? <><span className="badge on">Online</span> {st.online}/{st.max_players} players</>
          : <><span className="badge off">Stale</span> <span className="mut">last update {new Date(st.updated_at).toLocaleString()}</span></>}
      </div>
      <div className="card"><h2>Playtime leaderboard</h2>
        {rows === null ? <span className="mut">Loading…</span> : rows.length === 0 ? <span className="mut">No players yet.</span> :
        <table><thead><tr><th>#</th><th>Player</th><th>Hours</th></tr></thead><tbody>
          {rows.map((r, i) => <tr key={r.website_username}><td>{i + 1}</td><td>{r.minecraft_username ?? r.website_username}</td><td>{(r.total_seconds / 3600).toFixed(1)}</td></tr>)}
        </tbody></table>}
      </div>
    </div></>);
}
