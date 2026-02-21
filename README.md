# Antonisnts.github.io
import { useState, useEffect } from “react”;

const Check = ({ size = 16 }) => (
<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
<polyline points="20 6 9 17 4 12" />
</svg>
);
const Shield = ({ size = 16 }) => (
<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
</svg>
);
const Lock = ({ size = 16 }) => (
<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
<rect x="3" y="11" width="18" height="11" rx="2" ry="2" />
<path d="M7 11V7a5 5 0 0 1 10 0v4" />
</svg>
);
const RefreshCcw = ({ size = 16 }) => (
<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
<polyline points="1 4 1 10 7 10" /><polyline points="23 20 23 14 17 14" />
<path d="M20.49 9A9 9 0 0 0 5.64 5.64L1 10m22 4l-4.64 4.36A9 9 0 0 1 3.51 15" />
</svg>
);
const ClipboardCheck = ({ size = 16 }) => (
<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
<path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2" />
<rect x="8" y="2" width="8" height="4" rx="1" ry="1" />
<path d="m9 14 2 2 4-4" />
</svg>
);

const SnakeWatermark = () => (
<svg
viewBox=“0 0 400 400”
className=“absolute top-[-5%] left-1/2 pointer-events-none”
style={{
width: ‘130%’,
height: ‘55%’,
transform: ‘translateX(-50%)’,
opacity: 0.07,
filter: ‘grayscale(1)’,
maskImage: ‘radial-gradient(circle, black 30%, transparent 75%)’,
WebkitMaskImage: ‘radial-gradient(circle, black 30%, transparent 75%)’,
}}

```
{/* Coiled snake SVG art */}
<g fill="none" stroke="#00CFFF" strokeWidth="8" strokeLinecap="round">
  {/* Outer coil */}
  <path d="M200 50 C320 50, 370 120, 370 200 C370 290, 300 350, 200 350 C100 350, 30 290, 30 200 C30 110, 100 50, 200 50" />
  {/* Middle coil */}
  <path d="M200 90 C290 90, 330 150, 330 200 C330 265, 275 310, 200 310 C125 310, 70 265, 70 200 C70 135, 115 90, 200 90" />
  {/* Inner coil */}
  <path d="M200 130 C260 130, 290 165, 290 200 C290 245, 255 270, 200 270 C145 270, 110 245, 110 200 C110 155, 140 130, 200 130" />
  {/* Head */}
  <ellipse cx="200" cy="175" rx="22" ry="18" fill="#00CFFF" stroke="none" />
  {/* Eyes */}
  <circle cx="192" cy="170" r="4" fill="#0a0a0a" stroke="none" />
  <circle cx="208" cy="170" r="4" fill="#0a0a0a" stroke="none" />
  {/* Tongue */}
  <path d="M200 192 L196 204 M200 192 L204 204" strokeWidth="3" />
  {/* Scales pattern suggestion */}
  <path d="M150 200 C150 195 160 190 170 195 C160 200 150 205 150 200" strokeWidth="2" opacity="0.5" />
  <path d="M230 200 C230 195 240 190 250 195 C240 200 230 205 230 200" strokeWidth="2" opacity="0.5" />
  <path d="M170 230 C170 225 180 220 190 225 C180 230 170 235 170 230" strokeWidth="2" opacity="0.5" />
  <path d="M210 230 C210 225 220 220 230 225 C220 230 210 235 210 230" strokeWidth="2" opacity="0.5" />
</g>
```

  </svg>
);

export default function App() {
const [isLocked, setIsLocked] = useState(false);
const [mounted, setMounted] = useState(false);
const [triggers, setTriggers] = useState({
elevated: false,
stakes: false,
overwhelmed: false,
longterm: false,
});
const [rules, setRules] = useState({
delay: false,
block: false,
leverage: false,
});
const [decisions, setDecisions] = useState(””);
const [frictionAnswer, setFrictionAnswer] = useState(””);
const [precisionCheck, setPrecisionCheck] = useState(null);
const [sealPulse, setSealPulse] = useState(false);

useEffect(() => {
setTimeout(() => setMounted(true), 100);
}, []);

const toggleTrigger = (key) => {
if (isLocked) return;
setTriggers((prev) => ({ …prev, [key]: !prev[key] }));
};

const toggleRule = (key) => {
if (isLocked) return;
setRules((prev) => ({ …prev, [key]: !prev[key] }));
};

const handleSeal = () => {
setSealPulse(true);
setTimeout(() => {
setIsLocked(true);
setSealPulse(false);
window.scrollTo({ top: 0, behavior: “smooth” });
}, 600);
};

const handleReset = () => {
if (confirm(“Reset current protocol state?”)) {
setIsLocked(false);
setTriggers({ elevated: false, stakes: false, overwhelmed: false, longterm: false });
setRules({ delay: false, block: false, leverage: false });
setDecisions(””);
setFrictionAnswer(””);
setPrecisionCheck(null);
}
};

const activeTriggersCount = Object.values(triggers).filter(Boolean).length;
const activeRulesCount = Object.values(rules).filter(Boolean).length;

return (
<>
<style>{`
@import url(‘https://fonts.googleapis.com/css2?family=Syne:wght@400;500;600;700;800&family=Syne+Mono&display=swap’);

```
    * { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      background: #0a0a0a;
      font-family: 'Syne', sans-serif;
    }

    .mono { font-family: 'Syne Mono', monospace; }

    .scan-line {
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      background: repeating-linear-gradient(
        0deg,
        transparent,
        transparent 2px,
        rgba(0,207,255,0.012) 2px,
        rgba(0,207,255,0.012) 4px
      );
      pointer-events: none;
      z-index: 9999;
    }

    .noise-overlay {
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noise'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noise)' opacity='0.05'/%3E%3C/svg%3E");
      opacity: 0.25;
      pointer-events: none;
      z-index: 9998;
      mix-blend-mode: overlay;
    }

    .fade-in {
      opacity: 0;
      transform: translateY(20px);
      transition: opacity 0.8s ease, transform 0.8s ease;
    }
    .fade-in.visible {
      opacity: 1;
      transform: translateY(0);
    }

    .trigger-btn {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 16px 20px;
      border: 1px solid rgba(255,255,255,0.08);
      background: transparent;
      color: rgba(255,255,255,0.4);
      cursor: pointer;
      transition: all 0.3s ease;
      text-align: left;
      width: 100%;
      font-family: 'Syne', sans-serif;
      font-size: 11px;
      letter-spacing: 0.15em;
      text-transform: uppercase;
      font-weight: 600;
      position: relative;
      overflow: hidden;
    }
    .trigger-btn::before {
      content: '';
      position: absolute;
      left: -100%;
      top: 0; bottom: 0;
      width: 100%;
      background: linear-gradient(90deg, transparent, rgba(0,207,255,0.05), transparent);
      transition: left 0.4s ease;
    }
    .trigger-btn:hover::before { left: 100%; }
    .trigger-btn:hover:not(.active) {
      border-color: rgba(255,255,255,0.2);
      color: rgba(255,255,255,0.7);
    }
    .trigger-btn.active {
      border-color: rgba(0,207,255,0.6);
      background: rgba(0,207,255,0.04);
      color: #fff;
    }
    .trigger-btn.locked { cursor: default; }
    .trigger-btn.locked:hover::before { left: -100%; }

    .check-box {
      width: 20px; height: 20px;
      border: 1px solid rgba(255,255,255,0.2);
      display: flex; align-items: center; justify-content: center;
      flex-shrink: 0;
      transition: all 0.3s ease;
    }
    .check-box.active {
      background: #00CFFF;
      border-color: #00CFFF;
      color: #000;
    }

    .rule-row {
      display: flex;
      gap: 16px;
      align-items: flex-start;
      cursor: pointer;
      transition: opacity 0.3s ease;
    }
    .rule-row:hover { opacity: 1 !important; }
    .rule-row.locked { pointer-events: none; }

    .rule-check {
      width: 24px; height: 24px;
      border: 1px solid rgba(255,255,255,0.3);
      display: flex; align-items: center; justify-content: center;
      flex-shrink: 0;
      margin-top: 2px;
      transition: all 0.3s ease;
    }
    .rule-check.active {
      background: #00CFFF;
      border-color: #00CFFF;
      color: #000;
    }

    .seal-btn {
      background: #00CFFF;
      color: #000;
      border: none;
      padding: 18px 48px;
      font-family: 'Syne', sans-serif;
      font-size: 10px;
      font-weight: 800;
      letter-spacing: 0.45em;
      text-transform: uppercase;
      cursor: pointer;
      transition: all 0.3s ease;
      display: flex; align-items: center; gap: 12px;
      box-shadow: 0 0 40px rgba(0,207,255,0.15), 0 0 80px rgba(0,207,255,0.07);
      position: relative;
      overflow: hidden;
    }
    .seal-btn::after {
      content: '';
      position: absolute;
      inset: 0;
      background: rgba(255,255,255,0);
      transition: background 0.3s ease;
    }
    .seal-btn:hover { box-shadow: 0 0 60px rgba(0,207,255,0.25), 0 0 120px rgba(0,207,255,0.1); filter: brightness(1.08); }
    .seal-btn:active { transform: scale(0.98); }
    .seal-btn.pulsing { animation: sealPulse 0.6s ease forwards; }

    @keyframes sealPulse {
      0% { transform: scale(1); box-shadow: 0 0 40px rgba(0,207,255,0.15); }
      50% { transform: scale(0.97); box-shadow: 0 0 100px rgba(0,207,255,0.5); }
      100% { transform: scale(1); box-shadow: 0 0 40px rgba(0,207,255,0.15); }
    }

    .locked-badge {
      display: flex; align-items: center; gap: 10px;
      color: #00CFFF;
      background: rgba(0,207,255,0.07);
      border: 1px solid rgba(0,207,255,0.2);
      padding: 14px 24px;
      animation: fadeUp 0.8s ease forwards;
    }
    @keyframes fadeUp {
      from { opacity: 0; transform: translateY(12px); }
      to { opacity: 1; transform: translateY(0); }
    }

    .reset-btn {
      background: none;
      border: none;
      font-family: 'Syne', sans-serif;
      font-size: 9px;
      letter-spacing: 0.4em;
      text-transform: uppercase;
      color: rgba(255,255,255,0.25);
      cursor: pointer;
      display: flex; align-items: center; gap: 8px;
      transition: color 0.3s ease;
    }
    .reset-btn:hover { color: rgba(255,255,255,0.8); }

    .precision-btn {
      padding: 12px 24px;
      border: 1px solid rgba(255,255,255,0.1);
      background: transparent;
      font-family: 'Syne', sans-serif;
      font-size: 9px;
      letter-spacing: 0.3em;
      text-transform: uppercase;
      color: rgba(255,255,255,0.3);
      cursor: pointer;
      transition: all 0.3s ease;
      font-weight: 600;
    }
    .precision-btn:hover:not(.locked) {
      border-color: rgba(255,255,255,0.3);
      color: rgba(255,255,255,0.7);
    }
    .precision-btn.emotion.active {
      background: rgba(239,68,68,0.12);
      border-color: rgba(239,68,68,0.7);
      color: rgb(239,68,68);
    }
    .precision-btn.precision-opt.active {
      background: rgba(0,207,255,0.1);
      border-color: rgba(0,207,255,0.7);
      color: #00CFFF;
    }
    .precision-btn.locked { cursor: default; }

    .glitch-text {
      position: relative;
    }
    .glitch-text::before, .glitch-text::after {
      content: attr(data-text);
      position: absolute;
      top: 0; left: 0;
      opacity: 0;
    }
    .glitch-text:hover::before {
      opacity: 0.6;
      color: #00CFFF;
      clip: rect(0, 900px, 2px, 0);
      animation: glitch1 0.3s ease;
    }
    .glitch-text:hover::after {
      opacity: 0.4;
      color: #ff006e;
      clip: rect(5px, 900px, 7px, 0);
      animation: glitch2 0.3s ease 0.1s;
    }
    @keyframes glitch1 {
      0% { transform: translateX(-2px); }
      50% { transform: translateX(2px); }
      100% { transform: translateX(0); opacity: 0; }
    }
    @keyframes glitch2 {
      0% { transform: translateX(2px); }
      50% { transform: translateX(-2px); }
      100% { transform: translateX(0); opacity: 0; }
    }

    textarea, input[type="text"] {
      font-family: 'Syne', sans-serif;
    }

    .progress-bar {
      height: 2px;
      background: rgba(255,255,255,0.06);
      position: relative;
      overflow: hidden;
    }
    .progress-bar-fill {
      height: 100%;
      background: linear-gradient(90deg, #00CFFF, rgba(0,207,255,0.4));
      transition: width 0.5s ease;
      box-shadow: 0 0 8px rgba(0,207,255,0.6);
    }

    .corner-mark {
      position: absolute;
      width: 10px; height: 10px;
      border-color: rgba(0,207,255,0.3);
      border-style: solid;
    }
    .corner-tl { top: 0; left: 0; border-width: 1px 0 0 1px; }
    .corner-tr { top: 0; right: 0; border-width: 1px 1px 0 0; }
    .corner-bl { bottom: 0; left: 0; border-width: 0 0 1px 1px; }
    .corner-br { bottom: 0; right: 0; border-width: 0 1px 1px 0; }

    .caret-cyan { caret-color: #00CFFF; }

    .stat-counter {
      font-size: 9px;
      font-weight: 700;
      letter-spacing: 0.3em;
      text-transform: uppercase;
      color: rgba(0,207,255,0.6);
      font-family: 'Syne Mono', monospace;
    }
  `}</style>

  <div className="scan-line" />
  <div className="noise-overlay" />

  <div style={{ minHeight: '100vh', background: '#0a0a0a', display: 'flex', justifyContent: 'center' }}>
    <div style={{
      position: 'relative',
      width: '100%',
      maxWidth: '820px',
      background: '#111111',
      color: 'white',
      padding: 'clamp(32px, 5vw, 80px)',
      minHeight: '100vh',
      borderLeft: '1px solid rgba(255,255,255,0.04)',
      borderRight: '1px solid rgba(255,255,255,0.04)',
      overflow: 'hidden',
    }}>

      {/* Snake Watermark */}
      <SnakeWatermark />

      {/* Ambient glow */}
      <div style={{
        position: 'absolute',
        top: '-100px', left: '50%',
        transform: 'translateX(-50%)',
        width: '600px', height: '600px',
        background: 'radial-gradient(circle, rgba(0,207,255,0.04) 0%, transparent 70%)',
        pointerEvents: 'none',
      }} />

      <div style={{ position: 'relative', zIndex: 10 }}>

        {/* ── HEADER ── */}
        <header className={`fade-in ${mounted ? 'visible' : ''}`} style={{ marginBottom: '60px', transitionDelay: '0ms' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: '8px' }}>
            <div>
              <h1
                className="glitch-text"
                data-text="MODE PROTOCOL"
                style={{ fontSize: 'clamp(32px, 6vw, 52px)', fontWeight: 800, letterSpacing: '-0.03em', lineHeight: 1, marginBottom: '6px' }}
              >
                MODE PROTOCOL
              </h1>
              <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
                <span style={{ color: '#00CFFF', fontSize: 'clamp(13px, 2vw, 17px)', fontWeight: 600, letterSpacing: '0.25em', textTransform: 'uppercase' }}>
                  Strategic State
                </span>
                {isLocked && <Lock size={14} style={{ color: '#00CFFF' }} />}
              </div>
            </div>

            <div style={{
              border: '1px solid rgba(0,207,255,0.3)',
              padding: '8px',
              marginTop: '4px',
              position: 'relative',
            }}>
              <div className="corner-mark corner-tl" />
              <div className="corner-mark corner-br" />
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#00CFFF" strokeWidth="1.5">
                <path d="M12 4L20 18H4L12 4Z" />
              </svg>
            </div>
          </div>

          <p style={{ fontSize: 'clamp(16px, 2.5vw, 22px)', fontWeight: 300, fontStyle: 'italic', opacity: 0.5, margin: '28px 0 20px' }}>
            "I do not react. I position."
          </p>

          <div style={{ height: '1px', background: 'linear-gradient(90deg, #00CFFF, rgba(0,207,255,0.1))', opacity: 0.5 }} />

          <div style={{ marginTop: '14px', display: 'flex', flexWrap: 'wrap', gap: '6px 20px' }}>
            {[
              '🐍 Symbol: Snake',
              '● Purpose: Accuracy',
              `● State: ${isLocked ? 'Active / Locked' : 'Open'}`,
            ].map((item) => (
              <span key={item} className="mono" style={{ fontSize: '9px', letterSpacing: '0.25em', opacity: 0.35, textTransform: 'uppercase' }}>
                {item}
              </span>
            ))}
          </div>

          {/* Progress summary */}
          <div style={{ marginTop: '20px', display: 'flex', alignItems: 'center', gap: '16px' }}>
            <div className="progress-bar" style={{ flex: 1 }}>
              <div className="progress-bar-fill" style={{ width: `${((activeTriggersCount + activeRulesCount + (precisionCheck ? 1 : 0) + (frictionAnswer.length > 5 ? 1 : 0)) / 9) * 100}%` }} />
            </div>
            <span className="stat-counter">{activeTriggersCount}/{4} triggers</span>
            <span className="stat-counter">{activeRulesCount}/{3} rules</span>
          </div>
        </header>

        {/* ── MAIN ── */}
        <main>

          {/* 1. TRIGGERS */}
          <section className={`fade-in ${mounted ? 'visible' : ''}`} style={{ marginBottom: '56px', transitionDelay: '100ms' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '20px' }}>
              <span className="mono" style={{ fontSize: '9px', letterSpacing: '0.35em', color: '#00CFFF', fontWeight: 700, textTransform: 'uppercase' }}>
                1 — Activate When
              </span>
              <span className="stat-counter">{activeTriggersCount} active</span>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))', gap: '10px' }}>
              {[
                { id: 'elevated', label: 'Emotion is elevated' },
                { id: 'stakes', label: 'Stakes are high' },
                { id: 'overwhelmed', label: 'You feel overwhelmed' },
                { id: 'longterm', label: 'Long-term decision required' },
              ].map((item) => (
                <button
                  key={item.id}
                  onClick={() => toggleTrigger(item.id)}
                  className={`trigger-btn ${triggers[item.id] ? 'active' : ''} ${isLocked ? 'locked' : ''}`}
                >
                  <span>{item.label}</span>
                  <div className={`check-box ${triggers[item.id] ? 'active' : ''}`}>
                    {triggers[item.id] && <Check size={12} />}
                  </div>
                </button>
              ))}
            </div>
          </section>

          {/* CORE PRINCIPLE */}
          <section className={`fade-in ${mounted ? 'visible' : ''}`} style={{ marginBottom: '56px', borderLeft: '2px solid #00CFFF', paddingLeft: '28px', paddingTop: '4px', paddingBottom: '4px', transitionDelay: '150ms' }}>
            <span className="mono" style={{ fontSize: '9px', letterSpacing: '0.35em', color: '#00CFFF', opacity: 0.55, textTransform: 'uppercase', fontWeight: 700 }}>Core Principle</span>
            <p style={{ fontSize: 'clamp(16px, 2.5vw, 22px)', fontWeight: 700, letterSpacing: '-0.01em', fontStyle: 'italic', margin: '10px 0 6px' }}>
              Speed reacts. Precision dominates.
            </p>
            <p style={{ fontSize: '13px', opacity: 0.45, fontWeight: 300 }}>Reducing impulse improves decision quality.</p>
          </section>

          {/* 2 & 3. RULES + TEXTAREA */}
          <section className={`fade-in ${mounted ? 'visible' : ''}`} style={{ marginBottom: '56px', display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: '48px', transitionDelay: '200ms' }}>

            <div>
              <span className="mono" style={{ fontSize: '9px', letterSpacing: '0.35em', color: '#00CFFF', fontWeight: 700, textTransform: 'uppercase', display: 'block', marginBottom: '24px' }}>
                2 — Execution Rules
              </span>
              <div style={{ display: 'flex', flexDirection: 'column', gap: '28px' }}>
                {[
                  { id: 'delay', label: 'Response Delay', desc: 'No commitments same day.' },
                  { id: 'block', label: '45m Strategic Block', desc: 'Phone off. Externalize thoughts.' },
                  { id: 'leverage', label: 'One-Leverage Move', desc: 'Single action simplifies all.' },
                ].map((rule) => (
                  <div
                    key={rule.id}
                    onClick={() => toggleRule(rule.id)}
                    className={`rule-row ${isLocked ? 'locked' : ''}`}
                    style={{ opacity: rules[rule.id] ? 1 : 0.35 }}
                  >
                    <div className={`rule-check ${rules[rule.id] ? 'active' : ''}`}>
                      {rules[rule.id] && <Check size={13} />}
                    </div>
                    <div>
                      <p style={{ fontSize: '11px', fontWeight: 700, letterSpacing: '0.2em', textTransform: 'uppercase' }}>{rule.label}</p>
                      <p style={{ fontSize: '11px', opacity: 0.5, fontWeight: 300, marginTop: '4px' }}>{rule.desc}</p>
                    </div>
                  </div>
                ))}
              </div>
            </div>

            <div>
              <span className="mono" style={{ fontSize: '9px', letterSpacing: '0.35em', color: '#00CFFF', fontWeight: 700, textTransform: 'uppercase', display: 'block', marginBottom: '20px' }}>
                3 — Strategic Input
              </span>
              <textarea
                placeholder="Draft decisions here. Clarity improves when externalized..."
                className="caret-cyan"
                style={{
                  width: '100%',
                  background: 'rgba(255,255,255,0.02)',
                  border: 'none',
                  borderBottom: '1px solid rgba(255,255,255,0.08)',
                  padding: '16px',
                  color: '#fff',
                  fontSize: '13px',
                  fontWeight: 300,
                  minHeight: '180px',
                  outline: 'none',
                  resize: 'none',
                  lineHeight: '1.8',
                  opacity: isLocked ? 0.55 : 1,
                  cursor: isLocked ? 'default' : 'text',
                  transition: 'border-color 0.3s ease',
                }}
                value={decisions}
                onChange={(e) => !isLocked && setDecisions(e.target.value)}
                disabled={isLocked}
                onFocus={(e) => { e.target.style.borderBottomColor = 'rgba(0,207,255,0.6)'; }}
                onBlur={(e) => { e.target.style.borderBottomColor = 'rgba(255,255,255,0.08)'; }}
              />
              <span className="stat-counter" style={{ marginTop: '8px', display: 'block' }}>
                {decisions.length > 0 ? `${decisions.length} chars` : 'empty'}
              </span>
            </div>
          </section>

          {/* 4. CONTROL QUESTION */}
          <section className={`fade-in ${mounted ? 'visible' : ''}`} style={{ marginBottom: '56px', paddingTop: '40px', borderTop: '1px solid rgba(255,255,255,0.05)', transitionDelay: '250ms' }}>
            <span className="mono" style={{ fontSize: '9px', letterSpacing: '0.35em', color: '#00CFFF', fontWeight: 700, textTransform: 'uppercase', display: 'block', marginBottom: '20px' }}>
              4 — Control Question
            </span>
            <p style={{ fontSize: 'clamp(16px, 2.5vw, 24px)', fontWeight: 300, fontStyle: 'italic', opacity: 0.75, marginBottom: '24px' }}>
              "What decision reduces future friction?"
            </p>
            <input
              type="text"
              placeholder="Type your answer..."
              className="caret-cyan"
              style={{
                width: '100%',
                background: 'transparent',
                border: 'none',
                borderBottom: '1px solid rgba(255,255,255,0.08)',
                padding: '14px 0',
                color: '#fff',
                fontSize: 'clamp(15px, 2vw, 20px)',
                fontWeight: 300,
                outline: 'none',
                opacity: isLocked ? 0.55 : 1,
                cursor: isLocked ? 'default' : 'text',
                transition: 'border-color 0.3s ease',
              }}
              value={frictionAnswer}
              onChange={(e) => !isLocked && setFrictionAnswer(e.target.value)}
              disabled={isLocked}
              onFocus={(e) => { e.target.style.borderBottomColor = 'rgba(0,207,255,0.6)'; }}
              onBlur={(e) => { e.target.style.borderBottomColor = 'rgba(255,255,255,0.08)'; }}
            />
          </section>

          {/* 5. FINAL VALIDATION */}
          <section className={`fade-in ${mounted ? 'visible' : ''}`} style={{ marginBottom: '64px', display: 'flex', flexWrap: 'wrap', alignItems: 'center', justifyContent: 'space-between', gap: '24px', padding: '28px 28px', background: 'rgba(255,255,255,0.015)', border: '1px solid rgba(255,255,255,0.05)', position: 'relative', transitionDelay: '300ms' }}>
            <div className="corner-mark corner-tl" />
            <div className="corner-mark corner-br" />
            <div>
              <span className="mono" style={{ fontSize: '9px', letterSpacing: '0.35em', color: '#00CFFF', fontWeight: 700, textTransform: 'uppercase', display: 'block', marginBottom: '8px' }}>
                Final Validation
              </span>
              <p style={{ fontSize: '13px', opacity: 0.5 }}>Did I move with emotion — or with precision?</p>
            </div>
            <div style={{ display: 'flex', gap: '12px' }}>
              <button
                onClick={() => !isLocked && setPrecisionCheck('emotion')}
                className={`precision-btn emotion ${precisionCheck === 'emotion' ? 'active' : ''} ${isLocked ? 'locked' : ''}`}
              >Emotion</button>
              <button
                onClick={() => !isLocked && setPrecisionCheck('precision')}
                className={`precision-btn precision-opt ${precisionCheck === 'precision' ? 'active' : ''} ${isLocked ? 'locked' : ''}`}
              >Precision</button>
            </div>
          </section>

          {/* FOOTER ACTIONS */}
          <footer className={`fade-in ${mounted ? 'visible' : ''}`} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '28px', paddingTop: '20px', transitionDelay: '350ms' }}>
            {!isLocked ? (
              <button
                onClick={handleSeal}
                className={`seal-btn ${sealPulse ? 'pulsing' : ''}`}
              >
                <Shield size={15} />
                Seal Strategic Protocol
              </button>
            ) : (
              <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '20px' }}>
                <div className="locked-badge">
                  <ClipboardCheck size={16} />
                  <span className="mono" style={{ fontSize: '9px', letterSpacing: '0.25em', fontWeight: 700, textTransform: 'uppercase' }}>
                    Protocol Active &amp; Locked
                  </span>
                </div>
                <button onClick={handleReset} className="reset-btn">
                  <RefreshCcw size={11} />
                  Reset Protocol
                </button>
              </div>
            )}

            <div style={{ width: '100%', height: '1px', background: 'rgba(255,255,255,0.05)' }} />

            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '6px' }}>
              <span className="mono" style={{ fontSize: '8px', letterSpacing: '0.55em', opacity: 0.18, textTransform: 'uppercase' }}>
                Mode Protocol — Version 1.0.4
              </span>
              <div style={{ display: 'flex', gap: '8px', alignItems: 'center', opacity: 0.12 }}>
                {[...Array(5)].map((_, i) => (
                  <div key={i} style={{ width: '3px', height: '3px', background: '#00CFFF', borderRadius: '50%' }} />
                ))}
              </div>
            </div>
          </footer>

        </main>
      </div>
    </div>
  </div>
</>
```

);
}