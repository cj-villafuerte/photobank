import { FormEvent, useState } from "react";
import { Link } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, ApiError } from "../api";
import { isDesktop } from "../App";
import { fmtBytes } from "../components/PhotoGrid";
import { useToast } from "../components/Toast";
import { UsersPanel } from "./Admin";
import { RedundancyBackup } from "./Settings";

/** Three numbered steps on first launch; can be re-run from the Console. */
function FirstRunSetup({ storageRoot, lanUrl, onDone }: { storageRoot: string; lanUrl: string; onDone: () => void }) {
  const toast = useToast();
  const qc = useQueryClient();
  const [folder, setFolder] = useState(storageRoot);
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [memberDone, setMemberDone] = useState(false);
  const canPick = !!window.pywebview?.api?.set_storage_root;

  const pickFolder = async () => {
    const picked = await window.pywebview?.api?.pick_folder?.();
    if (!picked) return;
    try {
      const applied = await window.pywebview!.api!.set_storage_root!(picked);
      setFolder(applied);
      toast("Photos will be stored in " + applied);
      qc.invalidateQueries({ queryKey: ["server"] });
    } catch (e) {
      toast(`Could not use that folder: ${e}`, true);
    }
  };

  const addMember = async (e: FormEvent) => {
    e.preventDefault();
    try {
      await api.createUser(email, password, name, false);
      setMemberDone(true);
      toast(`Member account for ${name} created`);
      qc.invalidateQueries({ queryKey: ["users"] });
    } catch (err) {
      toast(err instanceof ApiError ? err.message : "Could not create the account", true);
    }
  };

  return (
    <div className="settings-card" style={{ borderColor: "var(--ink)", marginBottom: 8 }}>
      <div style={{ fontFamily: "var(--font-display)", fontWeight: 700, fontSize: 26, letterSpacing: "-0.02em", marginBottom: 4 }}>
        Let's set this computer up<span style={{ color: "var(--accent)" }}>.</span>
      </div>
      <p className="muted" style={{ fontSize: "0.9rem", marginBottom: 18 }}>
        Three steps. You are the administrator of this library — no password needed on this computer.
      </p>

      <div className="settings-heading" style={{ marginTop: 0 }}>Where photos live</div>
      <div className="row" style={{ marginBottom: 6 }}>
        <code style={{ flex: 1, minWidth: 260 }}>{folder}</code>
        {canPick && <button onClick={pickFolder}>Choose a different folder…</button>}
      </div>
      <p className="muted" style={{ fontSize: "0.85rem", marginBottom: 18 }}>
        Originals are kept untouched here, organized by year and month. Pick a big drive if you have one.
      </p>

      <div className="settings-heading">A member account</div>
      {memberDone ? (
        <p style={{ marginBottom: 18 }}>Done — {name} can sign in from the phone app and the web.</p>
      ) : (
        <form className="row" style={{ marginBottom: 6 }} onSubmit={addMember}>
          <input placeholder="Name" value={name} onChange={(e) => setName(e.target.value)} required />
          <input type="email" placeholder="Email" value={email} onChange={(e) => setEmail(e.target.value)} required />
          <input type="password" placeholder="Password (min 8)" minLength={8} value={password} onChange={(e) => setPassword(e.target.value)} required />
          <button className="primary" type="submit">Create</button>
        </form>
      )}
      <p className="muted" style={{ fontSize: "0.85rem", marginBottom: 18 }}>
        Members have their own libraries and sign in with a password. You can reset any member's
        password from the Accounts section below. Skip this if it's just you — create one later.
      </p>

      <div className="settings-heading">The phone app</div>
      <p style={{ marginBottom: 6 }}>
        Install Photobank on the phone, keep it on this Wi-Fi, and it finds this computer by itself.
        Manual address if needed: <code>{lanUrl}</code>
      </p>
      <p className="muted" style={{ fontSize: "0.85rem", marginBottom: 18 }}>
        Sign in there with a member account. The phone backs up its camera roll here and can free
        space on the phone once photos are safely stored.
      </p>

      <button className="primary" onClick={onDone}>Finish setup</button>
    </div>
  );
}

/** The administrator's landing page: server first, then people, then safety. */
export default function Console() {
  const qc = useQueryClient();
  const { data: s } = useQuery({
    queryKey: ["server"],
    queryFn: api.serverInfo,
    refetchInterval: 10000,
  });
  const { data: flags } = useQuery({ queryKey: ["flags"], queryFn: api.flags });
  const [forceSetup, setForceSetup] = useState(false);
  const showSetup = isDesktop() && flags !== undefined && (forceSetup || flags.setup_done !== "1");

  const finishSetup = async () => {
    await api.setFlag("setup_done", "1");
    setForceSetup(false);
    qc.invalidateQueries({ queryKey: ["flags"] });
  };

  return (
    <div className="page" style={{ maxWidth: 1000 }}>
      <h1>Console</h1>
      <p className="muted" style={{ marginBottom: 8 }}>
        {isDesktop() ? (
          <>This computer hosts the library. Members see their photos on the phone app or in a
            browser; "View as member…" (top right) shows a member's library here.</>
        ) : (
          <>This server hosts the library. Manage it here; browse yours in the{" "}
            <Link to="/library" style={{ textDecoration: "underline" }}>Library</Link>.</>
        )}
        {isDesktop() && !showSetup && (
          <> · <button style={{ padding: "2px 8px", fontSize: 12 }} onClick={() => setForceSetup(true)}>Run setup again</button></>
        )}
      </p>

      {showSetup && s && (
        <FirstRunSetup storageRoot={s.storage_root} lanUrl={s.lan_url} onDone={finishSetup} />
      )}

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

      {/* per-account views: on the desktop the administrator has no library of their own */}
      {!isDesktop() && (
        <>
          <h2 className="settings-heading">Storage</h2>
          <div className="settings-card row">
            <Link to="/duplicates"><button>Find duplicate photos</button></Link>
            <Link to="/trash"><button>Trash</button></Link>
            <Link to="/stats"><button>Dashboard</button></Link>
          </div>
        </>
      )}
    </div>
  );
}
