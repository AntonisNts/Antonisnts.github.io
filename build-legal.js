// Generates the directory-index pages /privacy, /terms, /dpa from the *.md
// documents. Run: `node build-legal.js`.
//
// These pages used to ship React, ReactDOM and Babel standalone from unpkg and
// compile JSX in the browser — 2.8 MB of JavaScript to render a page of static
// text, and a blank page for the visitor whenever unpkg was unreachable. Since
// the markdown is known at build time and the documents have no interactive
// parts, the markup is produced here instead. The pages now load no external
// script at all and work with JavaScript disabled.
//
// The parser and the styles below are carried over from LegalPage.jsx, which
// this replaced, so the rendered result is unchanged.
const fs = require("fs");

const pages = [
  { dir: "privacy", title: "Privacy Policy",            md: "privacy-policy.md" },
  { dir: "terms",   title: "Terms of Service",          md: "terms-of-service.md" },
  { dir: "dpa",     title: "Data Processing Agreement", md: "data-processing-agreement.md" },
];

/* ---------- minimal markdown parsing (verbatim from LegalPage.jsx) ------- */

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

/* ---------- styles (the same objects LegalPage.jsx carried) -------------- */

const styles = {
  page: {
    minHeight: "100vh",
    background: "#f7f8fa",
    padding: "32px 16px",
    boxSizing: "border-box",
  },
  container: { maxWidth: 720, margin: "0 auto" },
  back: {
    background: "none",
    border: "none",
    color: "#2563eb",
    fontSize: 15,
    cursor: "pointer",
    padding: "4px 0",
    marginBottom: 16,
    // The back control is an <a> rather than a <button> now, so navigating home
    // needs no JavaScript. A button inherited the browser's form-control font
    // (Arial in Chrome); an anchor inherits from body, which is unstyled here,
    // so without this the link rendered in Times New Roman. The stack is the
    // article's own — intentional rather than whatever the UA happened to pick.
    display: "inline-block",
    textDecoration: "none",
    fontFamily:
      "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif",
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
  footer: { textAlign: "center", padding: "20px 4px 8px", fontSize: 14, color: "#6b7280" },
};

/* ---------- React's style-object semantics, reproduced -------------------
   A number becomes px, EXCEPT for the properties React treats as unitless —
   lineHeight and fontWeight are the two that appear here. Getting this wrong
   would silently change the type: line-height:1.65px rather than 1.65.        */

const UNITLESS = new Set([
  "lineHeight", "fontWeight", "opacity", "zIndex", "flex", "flexGrow",
  "flexShrink", "order", "zoom",
]);

function css(obj) {
  return Object.keys(obj).map(function (k) {
    const prop = k.replace(/[A-Z]/g, function (m) { return "-" + m.toLowerCase(); });
    let v = obj[k];
    if (typeof v === "number" && !UNITLESS.has(k)) v = v + "px";
    return prop + ":" + v;
  }).join(";");
}

const esc = s => String(s)
  .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const escAttr = s => esc(s).replace(/"/g, "&quot;");

// Inline **bold** -> <strong>, everything else escaped text. LegalPage wrapped
// the non-bold parts in style-less <span>s; those carried nothing and are
// dropped, so the visible result is identical and the markup is quieter.
function inline(text) {
  return String(text).split(/(\*\*[^*]+\*\*)/g).map(function (part) {
    if (part.startsWith("**") && part.endsWith("**")) {
      return "<strong>" + esc(part.slice(2, -2)) + "</strong>";
    }
    return esc(part);
  }).join("");
}

function renderBlock(block) {
  switch (block.type) {
    case "h1": return '<h1 style="' + escAttr(css(styles.h1)) + '">' + inline(block.text) + "</h1>";
    case "h2": return '<h2 style="' + escAttr(css(styles.h2)) + '">' + inline(block.text) + "</h2>";
    case "h3": return '<h3 style="' + escAttr(css(styles.h3)) + '">' + inline(block.text) + "</h3>";
    case "ul":
      return '<ul style="' + escAttr(css(styles.ul)) + '">' +
        block.items.map(function (item) {
          return '<li style="' + escAttr(css(styles.li)) + '">' + inline(item) + "</li>";
        }).join("") + "</ul>";
    default:   return '<p style="'  + escAttr(css(styles.p))  + '">' + inline(block.text) + "</p>";
  }
}

/* ---------- write the pages --------------------------------------------- */

const linkStyle = "color:#2563eb;text-decoration:none";

for (const p of pages) {
  const md = fs.readFileSync(p.md, "utf8");
  const body = parseMarkdown(md).map(renderBlock).join("\n          ");

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>${esc(p.title)} — PayStamp</title>
<style>html,body{margin:0;padding:0;background:#f7f8fa;}</style>
</head>
<body>
<div id="root">
  <div style="${escAttr(css(styles.page))}">
    <div style="${escAttr(css(styles.container))}">
      <a href="/" style="${escAttr(css(styles.back))}">← Back</a>
      <article style="${escAttr(css(styles.article))}">
          ${body}
      </article>
      <div style="${escAttr(css(styles.footer))}"><span><a href="/privacy" style="${linkStyle}">Privacy Policy</a>   ·   <a href="/terms" style="${linkStyle}">Terms of Service</a></span></div>
    </div>
  </div>
</div>
</body>
</html>
`;
  fs.mkdirSync(p.dir, { recursive: true });
  fs.writeFileSync(p.dir + "/index.html", html);
  console.log("wrote", p.dir + "/index.html", "(" + html.length + " bytes)");
}
