// Generates the directory-index pages /privacy, /terms, /dpa from the source
// LegalPage.jsx component + the *.md documents. Run: `node build-legal.js`.
// (No bundler: this is a single-file CDN app, so each legal route is a small
//  standalone page that renders LegalPage with the embedded markdown.)
const fs = require("fs");

// Adapt the ESM component to the in-browser Babel (React global) form.
let legal = fs.readFileSync("LegalPage.jsx", "utf8")
  .replace('import { useMemo } from "react";', "const { useMemo } = React;")
  .replace("export default function LegalPage", "function LegalPage");

const pages = [
  { dir: "privacy", title: "Privacy Policy",            md: "privacy-policy.md" },
  { dir: "terms",   title: "Terms of Service",          md: "terms-of-service.md" },
  { dir: "dpa",     title: "Data Processing Agreement", md: "data-processing-agreement.md" },
];

for (const p of pages) {
  const md = fs.readFileSync(p.md, "utf8");
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>${p.title} — PayStamp</title>
<style>html,body{margin:0;padding:0;background:#f7f8fa;}</style>
<script src="https://unpkg.com/react@18/umd/react.production.min.js" crossorigin></script>
<script src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js" crossorigin></script>
<script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
</head>
<body>
<div id="root"></div>
<script type="text/babel" data-presets="react">
${legal}

const MARKDOWN = ${JSON.stringify(md)};
ReactDOM.createRoot(document.getElementById("root")).render(
  <LegalPage title=${JSON.stringify(p.title)} markdown={MARKDOWN} onBack={()=>{ window.location.href = "/"; }}
    footer={<span><a href="/privacy" style={{color:"#2563eb",textDecoration:"none"}}>Privacy Policy</a>{"   \\u00b7   "}<a href="/terms" style={{color:"#2563eb",textDecoration:"none"}}>Terms of Service</a></span>} />
);
</script>
</body>
</html>
`;
  fs.mkdirSync(p.dir, { recursive: true });
  fs.writeFileSync(p.dir + "/index.html", html);
  console.log("wrote", p.dir + "/index.html", "(" + html.length + " bytes)");
}
