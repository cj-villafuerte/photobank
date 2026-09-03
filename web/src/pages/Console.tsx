import { Link } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { api } from "../api";
import { fmtBytes } from "../components/PhotoGrid";
import { UsersPanel } from "./Admin";
import { RedundancyBackup } from "./Settings";

/** The administrator's landing page: server first, then people, then safety. */
export default function Console() {
  const { data: s } = useQuery({
    queryKey: ["server"],
    queryFn: api.serverInfo,
    refetchInterval: 10000,
  });

  return (
    <div className="page" style={{ maxWidth: 1000 }}>
      <h1>Console</h1>
      <p className="muted" style={{ marginBottom: 8 }}>
        This computer hosts the library. Manage it here; browse it in the{" "}
        <Link to="/library" style={{ textDecoration: "underline" }}>Library</Link>.
      </p>

      <h2 className="settings-heading">Server</h2>
      <div className="settings-card">
        {!s ? (
          <span className="muted">Loading…</span>
        ) : (
          <>
            <div className="row" style={{ marginBottom: 12, alignItems: "stretch" }}>
              {[
                ["Items", String(s.assets)],
                ["Library", fmtBytes(s.bytes)],
                ["Accounts", String(s.users)],
                ["Processing", String(s.thumbs_pending + s.ocr_pending)],
              ].map(([label, v]) => (
                <div key={label} style={{ flex: 1, padding: "10px 12px", background: "var(--paper)", border: "var(--hairline)", borderRadius: "var(--radius)" }}>
                  <div style={{ fontFamily: "var(--font-display)", fontWeight: 700, fontSize: 26, letterSpacing: "-0.02em" }}>{v}</div>
                  <div className="mono muted" style={{ fontSize: 10 }}>{label}</div>
                </div>
              ))}
            </div>
            <div className="settings-row"><span className="muted">Address on this network</span><span><code>{s.lan_url}</code></span></div>
            <div className="settings-row"><span className="muted">Discovery</span>
              <span style={{ color: s.mdns.state === "announcing" ? "var(--ink)" : "var(--accent)" }}>
                {s.mdns.state === "announcing" ? `Announcing as ${s.mdns.instance?.split(".")[0] ?? s.hostname}` : `Not announcing${s.mdns.error ? ` — ${s.mdns.error}` : ""}`}
              </span>
            </div>
            <div className="settings-row"><span className="muted">Photos stored in</span><span><code>{s.storage_root}</code></span></div>
            <div className="settings-row"><span className="muted">Database</span><span>{s.database}</span></div>
            <div className="settings-row"><span className="muted">Machine</span><span>{s.hostname} · {s.platform}</span></div>
          </>
        )}
      </div>

      <h2 className="settings-heading">Accounts</h2>
      <div className="settings-card">
        <p className="muted" style={{ fontSize: "0.85rem", marginBottom: 12 }}>
          Members sign in with these accounts from the web app or the phone app. Each account has its
          own library.
        </p>
        <UsersPanel />
      </div>

      <RedundancyBackup />

      <h2 className="settings-heading">Storage</h2>
      <div className="settings-card row">
        <Link to="/duplicates"><button>Find duplicate photos</button></Link>
        <Link to="/trash"><button>Trash</button></Link>
        <Link to="/stats"><button>Dashboard</button></Link>
      </div>
    </div>
  );
}
