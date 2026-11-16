#!/usr/bin/env node
// Builds doc/customer-prerequisites-checklist.docx (Straiker look, real Word tick boxes) from the Markdown checklist.
//   NODE_PATH=<folder with node_modules/docx> node scripts/build-checklist-docx.js <logo.png>
// Needs the npm package `docx`. The logo is the gradient "S" square (render it from the HTML page's font, or pass any PNG).
const fs = require("fs"), path = require("path");
const D = require("docx");
const { Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, ImageRun, Header, Footer, PageNumber, AlignmentType, BorderStyle,
  WidthType, ShadingType, LevelFormat, PageOrientation, HeadingLevel, VerticalAlign, CheckBox } = D;

const ROOT = path.resolve(__dirname, "..");
const MD = fs.readFileSync(path.join(ROOT, "doc/customer-prerequisites-checklist.md"), "utf8").split("\n");
const LOGO = fs.readFileSync(process.argv[2] || path.join(ROOT, "doc/assets/straiker-logo.png"));
const OUT = path.join(ROOT, "doc/customer-prerequisites-checklist.docx");

const ROSE = "FF449E", GOLD = "FFB82A", TEAL = "307888", INK = "111111", MUTED = "666666", LINE = "CFCFC8", HEAD_BG = "EFEFEF", CODE_BG = "F3F3F3";
const FONT = "Arial", MONO = "Consolas";
const PAGE_W = 15840, PAGE_H = 12240, MARGIN = 1080, CONTENT = PAGE_W - 2 * MARGIN; // US Letter landscape, DXA

// ---- inline: `code`, **bold**, *italic* -> TextRuns
function runs(text, o = {}) {
  const size = o.size || 19, out = [], parts = text.replace(/\\\|/g, "|").split(/(`[^`]+`)/);
  for (const p of parts) {
    if (!p) continue;
    if (p.length > 1 && p.startsWith("`") && p.endsWith("`")) {
      out.push(new TextRun({ text: p.slice(1, -1), font: MONO, size: size - 2, color: o.color || INK, bold: o.bold, shading: { type: ShadingType.CLEAR, fill: CODE_BG, color: "auto" } }));
      continue;
    }
    const re = /\*\*(.+?)\*\*|(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])/g; let last = 0, m;
    while ((m = re.exec(p))) {
      if (m.index > last) out.push(new TextRun({ text: p.slice(last, m.index), font: FONT, size, color: o.color || INK, bold: o.bold }));
      out.push(new TextRun({ text: m[1] || m[2], font: FONT, size, color: o.color || INK, bold: m[1] ? true : o.bold, italics: !!m[2] }));
      last = m.index + m[0].length;
    }
    if (last < p.length) out.push(new TextRun({ text: p.slice(last), font: FONT, size, color: o.color || INK, bold: o.bold }));
  }
  return out;
}
const para = (text, o = {}) => new Paragraph({ children: runs(text, o), spacing: { before: o.before ?? 0, after: o.after ?? 100, line: 276 }, alignment: o.align });

// ---- tables
function splitRow(line) {
  line = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  const cells = []; let cur = "", tick = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === "`") tick = !tick;
    if (ch === "|" && !tick && line[i - 1] !== "\\") { cells.push(cur.trim()); cur = ""; } else cur += ch;
  }
  cells.push(cur.trim()); return cells;
}
const WHO = { Customer: TEAL, Straiker: ROSE, Both: MUTED };
const border = { style: BorderStyle.SINGLE, size: 4, color: LINE };
const borders = { top: border, bottom: border, left: border, right: border };
function cell(children, w, o = {}) {
  return new TableCell({ children, width: { size: w, type: WidthType.DXA }, borders, verticalAlign: o.v || VerticalAlign.TOP,
    shading: o.fill ? { type: ShadingType.CLEAR, fill: o.fill, color: "auto" } : undefined, margins: { top: 70, bottom: 70, left: 100, right: 100 } });
}
function cellParas(text) {
  if (WHO[text]) return [new Paragraph({ children: [new TextRun({ text: text.toUpperCase(), font: FONT, size: 15, bold: true, color: WHO[text] })] })];
  // split on <br>-free text; one paragraph per cell
  return [new Paragraph({ children: runs(text, { size: 17 }), spacing: { after: 0, line: 252 } })];
}
function widths(head, numbered) {
  const fixed = []; let total = 0; const w = [];
  const weight = (h) => /^(Item|What|Section 1 answer)$/.test(h) ? 1.2 : h === "Your answer" ? 1.5 : 2.2;
  const cols = [];
  if (numbered) { cols.push({ f: 650 }, { f: 650 }); head.slice(1).forEach((h) => cols.push(h === "Who" ? { f: 1300 } : { w: weight(h) })); }
  else head.forEach((h) => cols.push(h === "Who" ? { f: 1300 } : { w: weight(h) }));
  const fx = cols.reduce((s, c) => s + (c.f || 0), 0), wt = cols.reduce((s, c) => s + (c.w || 0), 0);
  const res = cols.map((c) => c.f || Math.floor((CONTENT - fx) * c.w / wt));
  res[res.length - 1] += CONTENT - res.reduce((a, b) => a + b, 0); return res;
}
function buildTable(rows) {
  const head = splitRow(rows[0]), body = rows.slice(2).map(splitRow);
  const numbered = head[0] === "#" && body.every((b) => /^\d+\.\d+$/.test(b[0]));
  const answer = numbered && head[1] === "Item" && head[2].startsWith("Rule");
  let heads = numbered ? ["Done", ...head] : head; if (answer) heads = [...heads, "Your answer"];
  const ws = widths(answer ? [...head, "Your answer"] : head, numbered);
  const mk = (t, w) => cell([new Paragraph({ children: [new TextRun({ text: t.toUpperCase(), font: FONT, size: 15, bold: true, color: MUTED })] })], w, { fill: HEAD_BG });
  const trs = [new TableRow({ tableHeader: true, children: heads.map((h, i) => mk(h, ws[i])) })];
  for (const b of body) {
    const cells = [];
    if (numbered) {
      cells.push(cell([new Paragraph({ alignment: AlignmentType.CENTER, children: [new CheckBox({ checked: false, checkedState: { value: "2612", font: "MS Gothic" }, uncheckedState: { value: "2610", font: "MS Gothic" } })] })], ws[0], { v: VerticalAlign.CENTER }));
      cells.push(cell([new Paragraph({ children: [new TextRun({ text: b[0], font: MONO, size: 16, color: MUTED })] })], ws[1]));
      b.slice(1).forEach((c, i) => cells.push(cell(cellParas(c), ws[i + 2])));
      if (answer) cells.push(cell([new Paragraph({ children: [new TextRun({ text: " ", size: 19 })] })], ws[ws.length - 1], { fill: "FAFAF6" }));
    } else b.forEach((c, i) => cells.push(cell(cellParas(c), ws[i])));
    trs.push(new TableRow({ cantSplit: true, children: cells }));
  }
  return new Table({ width: { size: CONTENT, type: WidthType.DXA }, layout: D.TableLayoutType.FIXED, columnWidths: ws, rows: trs });
}

// ---- document body
const body = []; let title = "", intro = [], inSection = false, i = 0, sign = 0;
const push = (x) => body.push(...(Array.isArray(x) ? x : [x]));
const sp = (after = 120) => new Paragraph({ children: [], spacing: { after } });
while (i < MD.length) {
  const ln = MD[i];
  if (ln.startsWith("# ")) { title = ln.slice(2).trim().replace(/^Straiker on-prem install:\s*/, ""); i++; continue; }
  if (ln.startsWith("## ")) {
    inSection = true;
    push(new Paragraph({ heading: HeadingLevel.HEADING_1, keepNext: true, pageBreakBefore: false, children: [new TextRun({ text: ln.slice(3).trim().toUpperCase(), font: FONT, bold: true, size: 26, color: INK })],
      spacing: { before: 360, after: 140 }, border: { bottom: { style: BorderStyle.SINGLE, size: 12, color: ROSE, space: 4 } } }));
    i++; continue;
  }
  if (ln.trim() === "---") { i++; continue; }
  if (ln.startsWith("```")) {
    const code = []; i++; while (!MD[i].startsWith("```")) code.push(MD[i++]); i++;
    code.forEach((l, k) => push(new Paragraph({ children: [new TextRun({ text: l || " ", font: MONO, size: 16 })],
      shading: { type: ShadingType.CLEAR, fill: CODE_BG, color: "auto" }, spacing: { before: 0, after: k === code.length - 1 ? 140 : 0, line: 252 },
      indent: { left: 140, right: 140 }, border: { left: { style: BorderStyle.SINGLE, size: 18, color: ROSE, space: 6 } } })));
    continue;
  }
  if (ln.startsWith("|")) { let j = i; while (j < MD.length && MD[j].startsWith("|")) j++; push(buildTable(MD.slice(i, j))); push(sp(160)); i = j; continue; }
  if (ln.startsWith(">")) {
    const t = []; while (i < MD.length && MD[i].startsWith(">")) t.push(MD[i++].replace(/^>\s?/, "").trim());
    push(new Paragraph({ children: runs(t.join(" "), { size: 19 }), shading: { type: ShadingType.CLEAR, fill: "FFF3F8", color: "auto" }, spacing: { before: 60, after: 160, line: 276 },
      indent: { left: 160, right: 160 }, border: { left: { style: BorderStyle.SINGLE, size: 24, color: ROSE, space: 8 } } })); continue;
  }
  if (/^- \[[ x]\] /.test(ln)) {
    while (i < MD.length && /^- \[[ x]\] /.test(MD[i])) {
      sign++; const t = MD[i].slice(6); i++;
      push(new Paragraph({ spacing: { after: 90 }, indent: { left: 400, hanging: 400 }, children: [
        new CheckBox({ checked: false, checkedState: { value: "2612", font: "MS Gothic" }, uncheckedState: { value: "2610", font: "MS Gothic" } }),
        new TextRun({ text: "  ", size: 19 }), ...runs(t)] }));
    }
    push(sp(80)); continue;
  }
  if (ln.startsWith("- ")) {
    while (i < MD.length && MD[i].startsWith("- ")) {
      let t = MD[i].slice(2); i++;
      while (i < MD.length && MD[i].startsWith("  ") && MD[i].trim()) t += " " + MD[i++].trim();
      push(new Paragraph({ numbering: { reference: "bul", level: 0 }, children: runs(t), spacing: { after: 80 } }));
    }
    push(sp(60)); continue;
  }
  if (ln.trim() === "") { i++; continue; }
  const t = []; while (i < MD.length && MD[i].trim() && !/^(```|\||>|- |## |# |---)/.test(MD[i])) t.push(MD[i++].trim());
  const text = t.join(" ");
  if (inSection) push(para(text, { after: 120 })); else intro.push(text);
}

const logoRun = (size) => new ImageRun({ type: "png", data: LOGO, transformation: { width: size, height: size }, altText: { title: "Straiker", description: "Straiker logo mark", name: "logo" } });
const head = [
  new Paragraph({ spacing: { before: 0, after: 60 }, children: [logoRun(34), new TextRun({ text: "    STRAIKER  ·  ON-PREM INSTALL", font: FONT, size: 17, color: MUTED, bold: true }),
    new TextRun({ text: "    NOV 2026", font: FONT, size: 15, color: ROSE, bold: true })] }),
  new Paragraph({ spacing: { before: 120, after: 160 }, children: [new TextRun({ text: title.toUpperCase(), font: FONT, bold: true, size: 52, color: INK })] }),
  ...intro.map((t) => para(t, { color: "444444", after: 100 })),
];

const doc = new Document({
  creator: "Straiker", title: "Straiker on-prem install: customer prerequisites checklist",
  styles: {
    default: { document: { run: { font: FONT, size: 19 } } },
    paragraphStyles: [{ id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
      run: { font: FONT, size: 26, bold: true }, paragraph: { spacing: { before: 360, after: 140 }, keepNext: true, outlineLevel: 0 } }],
  },
  numbering: { config: [{ reference: "bul", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 540, hanging: 270 } } } }] }] },
  sections: [{
    properties: { page: { size: { width: PAGE_H, height: PAGE_W, orientation: PageOrientation.LANDSCAPE }, margin: { top: 1000, bottom: 900, left: MARGIN, right: MARGIN } } },
    headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT, children: [new TextRun({ text: "Straiker  ·  Customer prerequisites checklist", font: FONT, size: 15, color: MUTED })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({ border: { top: { style: BorderStyle.SINGLE, size: 4, color: LINE, space: 6 } }, tabStops: [{ type: D.TabStopType.RIGHT, position: CONTENT }],
      children: [new TextRun({ text: "Tick each item, fill in the answers, and send the file back to Straiker.", font: FONT, size: 15, color: MUTED }),
        new TextRun({ children: ["\tPage ", PageNumber.CURRENT, " of ", PageNumber.TOTAL_PAGES], font: FONT, size: 15, color: MUTED })] })] }) },
    children: [...head, ...body],
  }],
});
Packer.toBuffer(doc).then((b) => { fs.writeFileSync(OUT, b); console.log("wrote", OUT, Math.round(b.length / 1024) + " KB"); });
