#!/usr/bin/env python3
"""Builds doc/customer-prerequisites-checklist.html (Straiker-styled, tickable) from the Markdown checklist.

    python3 scripts/build-checklist-html.py

Input:  doc/customer-prerequisites-checklist.md   Output: doc/customer-prerequisites-checklist.html
The page works offline: tick boxes and answer fields are kept in the browser (localStorage), a progress bar counts the ticks,
"Export answers" downloads a CSV to send back, "Print" gives a clean PDF. Brand look follows Straiker's platform-architecture page.
"""
import html, re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "doc/customer-prerequisites-checklist.md"
OUT = ROOT / "doc/customer-prerequisites-checklist.html"
FONT = (ROOT / "doc/assets/pressio-font.css").read_text()

def inline(t):
    codes = []
    def keep(m):
        codes.append("<code>" + html.escape(m.group(1).replace("\\|", "|")) + "</code>")
        return f"\x00{len(codes) - 1}\x00"
    t = re.sub(r"`([^`]+)`", keep, t)
    e = html.escape(t.replace("\\|", "|"), quote=False)
    e = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", e)
    e = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", e)
    return re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], e)

def split_row(line):
    line = line.strip().strip("|")
    cells, cur, tick = [], "", False
    for ch in line:
        if ch == "`":
            tick = not tick
        if ch == "|" and not tick and not cur.endswith("\\"):
            cells.append(cur.strip()); cur = ""
        else:
            cur += ch
    cells.append(cur.strip())
    return cells

WHO = {"Customer": "who-c", "Straiker": "who-s", "Both": "who-b"}

def cell(c):
    if c in WHO:
        return f'<span class="who {WHO[c]}">{c}</span>'
    return inline(c)

def table(rows):
    head = split_row(rows[0]); body = [split_row(r) for r in rows[2:]]
    numbered = head[0] == "#" and all(re.fullmatch(r"\d+\.\d+", b[0]) for b in body)
    answer = numbered and head[1] == "Item" and head[2].startswith("Rule")
    h = "".join(f"<th>{inline(c)}</th>" for c in head)
    if numbered:
        h = "<th class='tk'>Done</th>" + h + ("<th class='ans'>Your answer</th>" if answer else "")
    o = [f'<div class="card"><span class="corner tl"></span><span class="corner br"></span><div class="scroll"><table class="tt"><thead><tr>{h}</tr></thead><tbody>']
    for b in body:
        if numbered:
            i = b[0]
            tds = f'<td class="tk"><input type="checkbox" data-id="{i}" aria-label="Done {i}"></td>'
            tds += f'<td class="num">{i}</td>' + "".join(f"<td>{cell(c)}</td>" for c in b[1:])
            if answer:
                tds += f'<td class="ans"><input type="text" data-ans="{i}" placeholder="Type here" aria-label="Answer {i}"></td>'
            o.append(f'<tr data-row="{i}">{tds}</tr>')
        else:
            o.append("<tr>" + "".join(f"<td>{cell(c)}</td>" for c in b) + "</tr>")
    o.append("</tbody></table></div></div>")
    return "".join(o)

def parse(md):
    lines = md.split("\n"); i = 0; title = ""; intro = []; sections = []; cur = None; sign = 0
    def add(x):
        (cur["body"] if cur else intro).append(x)
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("# "):
            title = ln[2:].strip(); i += 1; continue
        if ln.startswith("## "):
            cur = {"title": ln[3:].strip(), "body": []}; sections.append(cur); i += 1; continue
        if ln.strip() == "---":
            i += 1; continue
        if ln.startswith("```"):
            j = i + 1; code = []
            while not lines[j].startswith("```"): code.append(lines[j]); j += 1
            body = html.escape("\n".join(code))
            add(f'<div class="code"><button class="copy" type="button">Copy</button><pre>{body}</pre></div>'); i = j + 1; continue
        if ln.startswith("|"):
            j = i
            while j < len(lines) and lines[j].startswith("|"): j += 1
            add(table(lines[i:j])); i = j; continue
        if ln.startswith(">"):
            j = i; t = []
            while j < len(lines) and lines[j].startswith(">"): t.append(lines[j].lstrip("> ").strip()); j += 1
            add('<div class="callout"><span class="corner tl"></span><span class="corner br"></span>' + inline(" ".join(t)) + "</div>"); i = j; continue
        if re.match(r"- \[[ x]\] ", ln):
            items = []
            while i < len(lines) and re.match(r"- \[[ x]\] ", lines[i]):
                sign += 1; txt = lines[i][6:]
                items.append(f'<li><label><input type="checkbox" data-id="S{sign}" data-text="{html.escape(re.sub("[`*]", "", txt), quote=True)}"><span>{inline(txt)}</span></label></li>'); i += 1
            add('<ul class="boxes">' + "".join(items) + "</ul>"); continue
        if ln.startswith("- "):
            items = []
            while i < len(lines) and lines[i].startswith("- "):
                t = lines[i][2:]; i += 1
                while i < len(lines) and lines[i].startswith("  ") and lines[i].strip(): t += " " + lines[i].strip(); i += 1
                items.append(f"<li>{inline(t)}</li>")
            add("<ul>" + "".join(items) + "</ul>"); continue
        if ln.strip() == "":
            i += 1; continue
        j = i; t = []
        while j < len(lines) and lines[j].strip() and not re.match(r"(```|\||>|- |## |# |---)", lines[j]):
            t.append(lines[j].strip()); j += 1
        add(f"<p>{inline(' '.join(t))}</p>"); i = j
    return title, intro, sections

CSS = """
:root{--smoke-0:hsl(0 0% 94%);--smoke-300:hsl(0 0% 52%);--smoke-600:hsl(0 0% 23%);--smoke-950:hsl(0 0% 7%);--smoke-1000:hsl(0 0% 2%);
--gris-500:hsl(0 0% 65%);--gris-800:hsl(0 0% 46%);--rose:hsl(331.12 100% 63.333%);--gold:hsl(40 100% 58.235%);--noir:hsl(49.565 9.3878% 51.961%);
--defend:hsl(191 48% 36%);--ok:hsl(122 45% 38%);--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
--foreground:var(--smoke-1000);--background:#fff;--secondary:color-mix(in hsl,var(--gris-500) 20%,transparent);--secondary-foreground:var(--gris-800);
--border:color-mix(in hsl,var(--noir) 30%,white);--ring:var(--rose);--tier-1:#fff;--corner:var(--noir);--grain:.035}
.dark{--foreground:var(--smoke-0);--background:var(--smoke-1000);--secondary:color-mix(in hsl,var(--smoke-0) 10%,black);--secondary-foreground:var(--smoke-300);
--border:var(--smoke-600);--tier-1:var(--smoke-950);--corner:var(--smoke-0);--defend:hsl(191 100% 65%);--ok:hsl(122 100% 76%);--grain:.06}
*,*::before,*::after{box-sizing:border-box}html,body{margin:0}
body{font:14px/1.55 Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",Helvetica,Arial,sans-serif;background:var(--background);color:var(--foreground);-webkit-font-smoothing:antialiased}
body::before{content:'';position:fixed;inset:0;pointer-events:none;z-index:100;opacity:var(--grain);background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E")}
::selection{background:var(--ring);color:#fff}
.display{font-family:Pressio,Inter,sans-serif;text-transform:uppercase;letter-spacing:.025em;font-weight:400}
.wrap{max-width:1180px;margin:0 auto;padding:0 24px 96px}
.page-head{display:flex;justify-content:space-between;align-items:flex-end;gap:24px;padding:28px 0 20px;flex-wrap:wrap}
.brand-row{display:flex;align-items:center;gap:10px;margin-bottom:16px;flex-wrap:wrap}
.logo{width:28px;height:28px;display:grid;place-items:center;background:linear-gradient(135deg,var(--rose),var(--gold));color:#000;font-size:18px;line-height:1}
.eyebrow{font-size:12px;color:var(--secondary-foreground);letter-spacing:.02em}
.badge{display:inline-flex;align-items:center;padding:0 5px;font-size:10px;line-height:16px;letter-spacing:.06em;text-transform:uppercase;border:1px solid var(--ring);color:var(--ring)}
.h1{font-size:44px;line-height:1.02;margin:0}.h2{font-size:28px;line-height:34px;margin:0}
.lede{max-width:820px;margin-top:14px;color:var(--secondary-foreground)}
.actions{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.btn{display:inline-flex;align-items:center;gap:6px;height:36px;padding:0 12px;font:500 14px Inter,system-ui,sans-serif;cursor:pointer;border:1px solid var(--border);background:var(--secondary);color:var(--foreground);transition:all .2s}
.btn:hover{background:color-mix(in hsl,var(--secondary) 60%,transparent)}
.btn:focus-visible,input:focus-visible{outline:none;border-color:var(--ring);box-shadow:0 0 0 3px color-mix(in hsl,var(--ring) 50%,transparent)}
.sep-h{height:1px;background:var(--border);position:relative;margin-bottom:20px}
.corner{position:absolute;width:12px;height:12px;border:0 solid var(--corner);pointer-events:none}
.corner.tl{top:0;left:0;border-top-width:3px;border-left-width:3px}.corner.br{bottom:0;right:0;border-bottom-width:3px;border-right-width:3px}
.progress{position:sticky;top:0;z-index:50;background:var(--background);padding:10px 0 12px;margin-bottom:8px;border-bottom:1px solid var(--border)}
.progress .row{display:flex;justify-content:space-between;font-size:12px;color:var(--secondary-foreground);margin-bottom:6px;letter-spacing:.02em}
.bar{height:6px;background:var(--secondary)}.bar>i{display:block;height:100%;width:0;background:linear-gradient(90deg,var(--rose),var(--gold));transition:width .25s}
section{margin-top:36px;display:grid;gap:12px}
p{margin:0}.muted{color:var(--secondary-foreground)}
.card{position:relative;border:1px solid var(--border);background:var(--tier-1)}.scroll{overflow-x:auto}
.tt{width:100%;border-collapse:collapse;font-size:13px}
.tt th,.tt td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--border);vertical-align:top}
.tt tr:last-child td{border-bottom:0}
.tt th{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--secondary-foreground);font-weight:600;background:var(--secondary);white-space:nowrap}
.tt td.num{font-family:var(--mono);font-size:12px;white-space:nowrap;color:var(--secondary-foreground)}
.tt .tk{width:52px;text-align:center}.tt .ans{min-width:220px}
.tt tr.done td{opacity:.55}.tt tr.done td.tk,.tt tr.done td.ans{opacity:1}
code{font-family:var(--mono);font-size:12px;background:var(--secondary);padding:1px 4px;word-break:break-word}
.code{position:relative;border:1px solid var(--border);background:var(--tier-1)}
.code pre{margin:0;padding:14px 76px 14px 16px;overflow-x:auto;font:12px/1.6 var(--mono)}
.copy{position:absolute;top:8px;right:8px;font:500 11px Inter,sans-serif;padding:3px 8px;cursor:pointer;border:1px solid var(--border);background:var(--secondary);color:var(--foreground)}
.callout{position:relative;border:1px solid var(--border);background:var(--tier-1);padding:14px 16px;font-size:13px;border-left:3px solid var(--ring)}
.callout strong{color:var(--foreground)}
input[type=checkbox]{appearance:none;-webkit-appearance:none;width:18px;height:18px;margin:0;border:1.5px solid var(--secondary-foreground);background:var(--background);cursor:pointer;position:relative;flex-shrink:0}\ninput[type=checkbox]:checked{border-color:transparent;background:linear-gradient(135deg,var(--rose),var(--gold))}\ninput[type=checkbox]:checked::after{content:'';position:absolute;left:5px;top:1px;width:5px;height:10px;border:solid #000;border-width:0 2px 2px 0;transform:rotate(45deg)}
input[type=text]{width:100%;font:13px Inter,sans-serif;padding:6px 8px;border:1px solid var(--border);background:var(--background);color:var(--foreground)}
.who{display:inline-block;font-size:10px;letter-spacing:.06em;text-transform:uppercase;padding:0 6px;line-height:18px;border:1px solid var(--border)}
.who-c{border-color:var(--defend);color:var(--defend)}.who-s{border-color:var(--ring);color:var(--ring)}.who-b{color:var(--secondary-foreground)}
ul{margin:0;padding-left:20px;display:grid;gap:4px}
ul.boxes{list-style:none;padding:0;border:1px solid var(--border);background:var(--tier-1)}
ul.boxes li{padding:9px 12px;border-bottom:1px solid var(--border)}ul.boxes li:last-child{border-bottom:0}
ul.boxes label{display:flex;gap:10px;align-items:flex-start;cursor:pointer}ul.boxes input{margin-top:2px;flex-shrink:0}
ul.boxes li.done span{opacity:.55;text-decoration:line-through}
footer{margin-top:56px;padding-top:16px;border-top:1px solid var(--border);font-size:12px;color:var(--secondary-foreground);display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}
@media print{.dark{--foreground:#000;--background:#fff;--tier-1:#fff;--secondary:#f1f1f1;--border:#ccc;--secondary-foreground:#555;--corner:#999;--defend:hsl(191 48% 36%);--ok:hsl(122 45% 30%)}
body::before,.actions,.progress,.copy{display:none!important}.wrap{padding:0}section{break-inside:auto}.card,.code,tr,.callout{break-inside:avoid}
input[type=text]{border:0;border-bottom:1px solid #999}}
@media(max-width:700px){.h1{font-size:30px}.wrap{padding:0 14px 64px}}
"""

JS = """
(function(){
var KEY='straiker-prereq-v1',st={};
try{st=JSON.parse(localStorage.getItem(KEY)||'{}')}catch(e){}
function save(){try{localStorage.setItem(KEY,JSON.stringify(st))}catch(e){}}
var boxes=[].slice.call(document.querySelectorAll('input[type=checkbox][data-id]'));
var bar=document.getElementById('bar'),cnt=document.getElementById('cnt');
function mark(b){var host=b.closest('tr')||b.closest('li');if(host)host.classList.toggle('done',b.checked)}
function update(){var n=boxes.filter(function(b){return b.checked}).length;cnt.textContent=n+' of '+boxes.length+' done';bar.style.width=(boxes.length?100*n/boxes.length:0)+'%'}
boxes.forEach(function(b){b.checked=!!st['c'+b.dataset.id];mark(b);b.addEventListener('change',function(){st['c'+b.dataset.id]=b.checked;mark(b);save();update()})});
[].forEach.call(document.querySelectorAll('input[data-ans]'),function(t){t.value=st['a'+t.dataset.ans]||'';t.addEventListener('input',function(){st['a'+t.dataset.ans]=t.value;save()})});
update();
[].forEach.call(document.querySelectorAll('.copy'),function(b){b.addEventListener('click',function(){var t=b.parentNode.querySelector('pre').innerText;
(navigator.clipboard?navigator.clipboard.writeText(t):Promise.reject()).then(function(){b.textContent='Copied';setTimeout(function(){b.textContent='Copy'},1500)},function(){b.textContent='Select and copy'})})});
function q(s){return '"'+String(s).replace(/"/g,'""')+'"'}
document.getElementById('export').addEventListener('click',function(){
var rows=[['Id','Item','Done','Your answer']];
[].forEach.call(document.querySelectorAll('tr[data-row]'),function(r){var id=r.dataset.row,c=r.querySelectorAll('td');
var a=r.querySelector('input[data-ans]');rows.push([id,c[2].innerText.trim(),r.querySelector('input[type=checkbox]').checked?'yes':'no',a?a.value:''])});
boxes.filter(function(b){return b.dataset.id[0]==='S'}).forEach(function(b){rows.push([b.dataset.id,b.dataset.text,b.checked?'yes':'no',''])});
var csv=rows.map(function(r){return r.map(q).join(',')}).join('\\r\\n');
var a=document.createElement('a');a.href=URL.createObjectURL(new Blob([csv],{type:'text/csv'}));a.download='straiker-prerequisites-answers.csv';document.body.appendChild(a);a.click();a.remove()});
document.getElementById('print').addEventListener('click',function(){window.print()});
var root=document.documentElement,tb=document.getElementById('theme');
try{if(localStorage.getItem('straiker-theme')==='dark')root.classList.add('dark')}catch(e){}
tb.addEventListener('click',function(){root.classList.toggle('dark');try{localStorage.setItem('straiker-theme',root.classList.contains('dark')?'dark':'light')}catch(e){}});
})();
"""

def main():
    title, intro, sections = parse(SRC.read_text())
    short = re.sub(r"^Straiker on-prem install:\s*", "", title)
    short = short[0].upper() + short[1:]
    lede = intro[0] if intro else ""
    rest = "".join(intro[1:])
    secs = "".join(f'<section><h2 class="h2 display">{inline(s["title"])}</h2>{"".join(s["body"])}</section>' for s in sections)
    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>{html.escape(short)} — Straiker</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
{FONT}
{CSS}
</style>
</head>
<body>
<div class="wrap">
  <header class="page-head">
    <div>
      <div class="brand-row"><div class="logo display">S</div><span class="eyebrow">Straiker · On-prem install</span><span class="badge">Nov 2026</span></div>
      <h1 class="h1 display">{html.escape(short)}</h1>
      <div class="lede">{lede}{rest}</div>
    </div>
    <div class="actions">
      <button class="btn" id="export" type="button">Export answers (CSV)</button>
      <button class="btn" id="print" type="button">Print / Save PDF</button>
      <button class="btn" id="theme" type="button">Light / dark</button>
    </div>
  </header>
  <div class="sep-h"></div>
  <div class="progress" role="status"><div class="row"><span>Your progress (saved in this browser)</span><span id="cnt">0 of 0 done</span></div><div class="bar"><i id="bar"></i></div></div>
  {secs}
  <footer><span>Straiker · On-prem install · Customer prerequisites</span><span>Tick each item, fill in the answers, then use Export answers and send the file back to Straiker.</span></footer>
</div>
<script>{JS}</script>
</body>
</html>
"""
    OUT.write_text(page)
    print(f"wrote {OUT} ({len(page)//1024} KB)")

main()
