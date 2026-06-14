import { useMemo } from "react";

/**
 * LegalPage — renders a markdown legal document (Privacy, Terms, or DPA).
 *
 * Usage:
 *   <LegalPage title="Privacy Policy" markdown={privacyMarkdown} onBack={() => navigate("/")} />
 *
 * Pass the .md file content as a string in `markdown`. A tiny built-in parser
 * handles the subset of markdown these documents use (# headings, **bold**,
 * - bullets, paragraphs). No external markdown library required.
 */
export default function LegalPage({ title, markdown, onBack }) {
  const blocks = useMemo(() => parseMarkdown(markdown), [markdown]);

  return (
    <div style={styles.page}>
      <div style={styles.container}>
        {onBack && (
          <button onClick={onBack} style={styles.back}>
            ← Back
          </button>
        )}
        <article style={styles.article}>
          {blocks.map((block, i) => renderBlock(block, i))}
        </article>
      </div>
    </div>
  );
}

/* ---------- minimal markdown parsing ---------- */

function parseMarkdown(md = "") {
  const lines = md.replace(/\r\n/g, "\n").split("\n");
  const blocks = [];
  let paragraph = [];
  let list = [];

  const flushParagraph = () => {
    if (paragraph.length) {
      blocks.push({ type: "p", text: paragraph.join(" ") });
      paragraph = [];
    }
  };
  const flushList = () => {
    if (list.length) {
      blocks.push({ type: "ul", items: [...list] });
      list = [];
    }
  };

  for (const raw of lines) {
    const line = raw.trimEnd();
    if (!line.trim()) {
      flushParagraph();
      flushList();
      continue;
    }
    if (line.startsWith("# ")) {
      flushParagraph(); flushList();
      blocks.push({ type: "h1", text: line.slice(2) });
    } else if (line.startsWith("## ")) {
      flushParagraph(); flushList();
      blocks.push({ type: "h2", text: line.slice(3) });
    } else if (line.startsWith("### ")) {
      flushParagraph(); flushList();
      blocks.push({ type: "h3", text: line.slice(4) });
    } else if (/^[-*]\s+/.test(line)) {
      flushParagraph();
      list.push(line.replace(/^[-*]\s+/, ""));
    } else {
      flushList();
      paragraph.push(line);
    }
  }
  flushParagraph();
  flushList();
  return blocks;
}

// Inline **bold** -> <strong>, leaving the rest as text.
function renderInline(text) {
  const parts = text.split(/(\*\*[^*]+\*\*)/g);
  return parts.map((part, i) => {
    if (part.startsWith("**") && part.endsWith("**")) {
      return <strong key={i}>{part.slice(2, -2)}</strong>;
    }
    return <span key={i}>{part}</span>;
  });
}

function renderBlock(block, i) {
  switch (block.type) {
    case "h1":
      return <h1 key={i} style={styles.h1}>{renderInline(block.text)}</h1>;
    case "h2":
      return <h2 key={i} style={styles.h2}>{renderInline(block.text)}</h2>;
    case "h3":
      return <h3 key={i} style={styles.h3}>{renderInline(block.text)}</h3>;
    case "ul":
      return (
        <ul key={i} style={styles.ul}>
          {block.items.map((item, j) => (
            <li key={j} style={styles.li}>{renderInline(item)}</li>
          ))}
        </ul>
      );
    default:
      return <p key={i} style={styles.p}>{renderInline(block.text)}</p>;
  }
}

/* ---------- styles (inline so the component is drop-in) ---------- */

const styles = {
  page: {
    minHeight: "100vh",
    background: "#f7f8fa",
    padding: "32px 16px",
    boxSizing: "border-box",
  },
  container: {
    maxWidth: 720,
    margin: "0 auto",
  },
  back: {
    background: "none",
    border: "none",
    color: "#2563eb",
    fontSize: 15,
    cursor: "pointer",
    padding: "4px 0",
    marginBottom: 16,
  },
  article: {
    background: "#ffffff",
    borderRadius: 12,
    padding: "40px 36px",
    boxShadow: "0 1px 3px rgba(0,0,0,0.06)",
    color: "#1f2937",
    lineHeight: 1.65,
    fontSize: 16,
    fontFamily:
      "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif",
  },
  h1: { fontSize: 26, fontWeight: 700, margin: "0 0 8px", color: "#111827" },
  h2: { fontSize: 19, fontWeight: 600, margin: "28px 0 8px", color: "#111827" },
  h3: { fontSize: 16, fontWeight: 600, margin: "20px 0 6px", color: "#111827" },
  p: { margin: "0 0 14px" },
  ul: { margin: "0 0 14px", paddingLeft: 22 },
  li: { margin: "0 0 6px" },
};
