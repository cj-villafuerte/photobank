import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api, DailyStat } from "../api";
import { fmtBytes } from "../components/PhotoGrid";

// Brief theme: bars in ink2 (a lone neutral series - contrast 12:1 on paper);
// the hovered bar is the composition's single accent.
const MARK = "#2B3239";
const MARK_HOT = "#FF4A1C";

interface Tip {
  x: number;
  y: number;
  lines: string[];
}

function fillDays(daily: DailyStat[], days: number): DailyStat[] {
  const byDate = new Map(daily.map((d) => [d.date, d]));
  const out: DailyStat[] = [];
  const now = new Date();
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(now);
    d.setDate(d.getDate() - i);
    const key = d.toISOString().slice(0, 10);
    out.push(byDate.get(key) ?? { date: key, count: 0, bytes: 0 });
  }
  return out;
}

function BarChart({
  title,
  data,
  value,
  format,
}: {
  title: string;
  data: DailyStat[];
  value: (d: DailyStat) => number;
  format: (v: number) => string;
}) {
  const [tip, setTip] = useState<Tip | null>(null);
  const W = 900;
  const H = 220;
  const PAD = { top: 16, right: 8, bottom: 24, left: 48 };
  const plotW = W - PAD.left - PAD.right;
  const plotH = H - PAD.top - PAD.bottom;
  const max = Math.max(1, ...data.map(value));
  const barW = plotW / data.length;

  // ~4 recessive gridlines on rounded values
  const gridSteps = 4;
  const gridVals = Array.from({ length: gridSteps }, (_, i) => (max * (i + 1)) / gridSteps);

  // sparse x labels: ~6 across
  const labelEvery = Math.max(1, Math.floor(data.length / 6));

  return (
    <div className="settings-card" style={{ marginBottom: 20, position: "relative" }}>
      <div style={{ marginBottom: 8, fontWeight: 600 }}>{title}</div>
      <svg
        viewBox={`0 0 ${W} ${H}`}
        style={{ width: "100%", height: "auto", display: "block" }}
        onMouseLeave={() => setTip(null)}
      >
        {gridVals.map((v, i) => {
          const y = PAD.top + plotH - (v / max) * plotH;
          return (
            <g key={i}>
              <line x1={PAD.left} x2={W - PAD.right} y1={y} y2={y} stroke="var(--border)" strokeWidth={1} />
              <text x={PAD.left - 6} y={y + 4} textAnchor="end" fontSize={11} fill="var(--text-dim)">
                {format(v)}
              </text>
            </g>
          );
        })}
        <line
          x1={PAD.left} x2={W - PAD.right}
          y1={PAD.top + plotH} y2={PAD.top + plotH}
          stroke="var(--border)" strokeWidth={1}
        />
        {data.map((d, i) => {
          const v = value(d);
          const h = (v / max) * plotH;
          const x = PAD.left + i * barW;
          return (
            <g key={d.date}>
              {v > 0 && (
                <rect
                  x={x + Math.min(1, barW * 0.15)}
                  y={PAD.top + plotH - h}
                  width={Math.max(1, barW - Math.min(2, barW * 0.3))}
                  height={h}
                  rx={Math.min(2, barW / 3)}
                  fill={tip && Math.abs(tip.x - ((x + barW / 2) / W) * 100) < 0.01 ? MARK_HOT : MARK}
                />
              )}
              {/* hover target wider than the mark */}
              <rect
                x={x} y={PAD.top} width={barW} height={plotH} fill="transparent"
                onMouseEnter={() =>
                  setTip({
                    x: ((x + barW / 2) / W) * 100,
                    y: ((PAD.top + plotH - h) / H) * 100,
                    lines: [
                      new Date(d.date).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }),
                      format(v),
                    ],
                  })
                }
              />
              {i % labelEvery === 0 && (
                <text
                  x={x + barW / 2} y={H - 6} textAnchor="middle" fontSize={11} fill="var(--text-dim)"
                >
                  {new Date(d.date).toLocaleDateString(undefined, { month: "short", day: "numeric" })}
                </text>
              )}
            </g>
          );
        })}
      </svg>
      {tip && (
        <div
          style={{
            position: "absolute",
            left: `${tip.x}%`,
            top: `calc(${tip.y}% )`,
            transform: "translate(-50%, -110%)",
            background: "var(--bg)",
            border: "1px solid var(--border)",
            borderRadius: 6,
            padding: "6px 10px",
            pointerEvents: "none",
            fontSize: "0.8rem",
            whiteSpace: "nowrap",
            zIndex: 5,
          }}
        >
          {tip.lines.map((l, i) => (
            <div key={i} className={i === 0 ? "muted" : undefined}>{l}</div>
          ))}
        </div>
      )}
    </div>
  );
}

export default function Stats() {
  const [days, setDays] = useState(90);
  const { data, isLoading } = useQuery({
    queryKey: ["stats", days],
    queryFn: () => api.stats(days),
  });

  const daily = useMemo(() => (data ? fillDays(data.daily, days) : []), [data, days]);

  return (
    <div className="page">
      <div className="row" style={{ justifyContent: "space-between", marginBottom: 16 }}>
        <h1 style={{ marginBottom: 0 }}>Dashboard</h1>
        <div className="row">
          {[30, 90, 365].map((d) => (
            <button
              key={d}
              className={days === d ? "primary" : undefined}
              onClick={() => setDays(d)}
            >
              {d} days
            </button>
          ))}
        </div>
      </div>

      {isLoading && <p className="muted">Loading…</p>}
      {data && (
        <>
          <div className="row" style={{ marginBottom: 20, alignItems: "stretch" }}>
            {[
              ["Items", String(data.total_count)],
              ["Photos", String(data.image_count)],
              ["Videos", String(data.video_count)],
              ["Library size", fmtBytes(data.total_bytes)],
            ].map(([label, v]) => (
              <div key={label} className="settings-card" style={{ flex: 1, textAlign: "center" }}>
                <div style={{ fontSize: "1.6rem", fontWeight: 600 }}>{v}</div>
                <div className="muted" style={{ fontSize: "0.85rem" }}>{label}</div>
              </div>
            ))}
          </div>

          <BarChart
            title={`Media per day (last ${days} days, by date taken)`}
            data={daily}
            value={(d) => d.count}
            format={(v) => `${Math.round(v)}`}
          />
          <BarChart
            title={`Storage added per day (last ${days} days)`}
            data={daily}
            value={(d) => d.bytes}
            format={(v) => fmtBytes(v)}
          />
        </>
      )}
    </div>
  );
}
