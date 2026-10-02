const ICONS = {
  a: { light: "__ICON_A_LIGHT__", dark: "__ICON_A_DARK__" },
  b: { light: "__ICON_B_LIGHT__", dark: "__ICON_B_DARK__" },
  c: { light: "__ICON_C_LIGHT__", dark: "__ICON_C_DARK__" }
};

const DIRS = {
  a: {
    name: "Golden Gate", tag: "native glass chrome",
    traits: [
      "Sidebar runs edge to edge as glass, with SF Symbols in the accent colour and a semibold selection, as Finder does on macOS 27.",
      "Each pane's tabs and path form one glass header; tabs are capsules, back and forward sit at the start of the path.",
      "System colours throughout, so Increase Contrast and Reduce Transparency work without extra code.",
      "Git status is a short rounded bar at the start of the row."
    ],
    os: "macOS 26+: glass sidebar, header and Quick Nav. macOS 27: click bounce on glass, concentric corners. macOS 14–15: sidebar and titlebar materials, same layout.",
    icon: "A route that bends around an obstacle, as a glass ribbon over blue-teal."
  },
  b: {
    name: "Quiet Pro", tag: "opaque warm neutrals",
    traits: [
      "Warm grey surfaces with the sidebar one step quieter than the files; no glass, so it looks the same on every macOS version.",
      "Compact tabs where the current one is a soft raised pill; the path is plain crumbs with chevrons.",
      "Sidebar symbols stay monochrome; only the selected item takes the accent.",
      "Git status is a small dot after the name; panes are split by a warm hairline instead of black."
    ],
    os: "Identical on macOS 14 to 27. On 26+ compact control metrics keep buttons dense.",
    icon: "Two overlapping panes in warm neutrals, the right one lifted."
  },
  c: {
    name: "Instrument", tag: "structured panels, mono data",
    traits: [
      "Each pane is a framed panel; the active pane's header takes a light accent tint, the inactive one stays neutral.",
      "Underlined tabs and a monospaced path; sortable column headers with Git, Size, Modified and Mode columns.",
      "Size, date and permissions in SF Mono with faint row rules instead of banding, so numbers read as a table.",
      "A persistent status line per pane that also shows the remote connection."
    ],
    os: "System sidebar material only (glass on 26+). Headers and panels stay opaque on every version.",
    icon: "A folder outline carrying a routed line with two nodes, graphite with a teal signal."
  }
};

const LEFT = {
  tabs: [["folder","Finance"],["folder","acme-corp",1],["drive","Specs.sparsebundle"]],
  crumbs: [["home","smith"],[null,"Projects"],[null,"acme-corp"]],
  monoPath: "~/Projects/acme-corp",
  rows: [
    {k:"folder", n:"contracts", s:"1.3 MB", d:"7 Jul", m:"drwxr-xr-x"},
    {k:"folder", n:"invoices", s:"345.5 KB", d:"7 Jul", m:"drwxr-xr-x"},
    {k:"folder", n:"reports", s:"5.9 MB", d:"7 Jul", m:"drwxr-xr-x"},
    {k:"folder", n:"team", s:"314.0 KB", d:"7 Jul", m:"drwxr-xr-x"},
    {k:"xlsx", n:"Budget-2026.xlsx", s:"129.7 KB", d:"10 Dec 2025", m:"-rw-r--r--", sel:1},
    {k:"pdf", n:"Company-Handbook.pdf", s:"2.2 MB", d:"15 Sep 2025", m:"-rw-r--r--"},
    {k:"md", n:"Meeting-Notes.md", s:"660 B", d:"15 Jan", m:"-rw-r--r--"}
  ],
  status: ["1 of 7 selected", "130 KB", "925.6 GB available"],
  remote: false
};
const RIGHT = {
  tabs: [["folder","INBOX"],["folder","Downloads"],["globe","api",1],["drive","Detours.dmg"]],
  crumbs: [["globe","devtest"],[null,"home"],[null,"maf"],[null,"Projects"],[null,"taskflow"],[null,"api"]],
  monoPath: "devtest:~/Projects/taskflow/api",
  rows: [
    {k:"folder", n:"middleware", s:"—", d:"7 Jul", m:"drwxr-xr-x"},
    {k:"folder", n:"schemas", s:"—", d:"7 Jul", m:"drwxr-xr-x"},
    {k:"py", n:"__init__.py", s:"50 B", d:"15 Sep 2025", m:"-rw-r--r--"},
    {k:"py", n:"cache.py", s:"265 B", d:"20 Jan", m:"-rw-r--r--", g:"unt"},
    {k:"py", n:"config.py", s:"353 B", d:"3 Nov 2025", m:"-rw-r--r--"},
    {k:"py", n:"database.py", s:"421 B", d:"20 Jan", m:"-rw-r--r--", g:"mod", sel:1},
    {k:"py", n:"main.py", s:"459 B", d:"20 Sep 2025", m:"-rwxr-xr-x"},
    {k:"py", n:"models.py", s:"744 B", d:"20 Jan", m:"-rw-r--r--", g:"add"},
    {k:"py", n:"notifications.py", s:"231 B", d:"19 Jan", m:"-rw-r--r--", g:"unt"},
    {k:"py", n:"routes.py", s:"501 B", d:"12 Oct 2025", m:"-rw-r--r--"},
    {k:"py", n:"utils.py", s:"473 B", d:"10 Nov 2025", m:"-rw-r--r--"}
  ],
  status: ["1 of 11 selected", "421 B"],
  remote: true
};
const GIT_LETTER = { mod: "M", add: "A", unt: "?" };
const GIT_NAME = { mod: "Modified", add: "Added", unt: "Untracked" };

/* SF Symbol-like line glyphs for chrome; stock-style file icons for the list. */
const G = {
  drive: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="1.5" y="5" width="13" height="6.5" rx="1.8"/><circle cx="11.6" cy="8.25" r=".7" fill="currentColor" stroke="none"/></svg>',
  disk: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M3 10.5 4.6 4.2A1.5 1.5 0 0 1 6 3h4a1.5 1.5 0 0 1 1.4 1.2L13 10.5"/><rect x="2.5" y="10" width="11" height="3.5" rx="1.2"/></svg>',
  globe: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2"><circle cx="8" cy="8" r="6.2"/><path d="M1.8 8h12.4M8 1.8c1.8 1.7 2.7 3.8 2.7 6.2S9.8 12.5 8 14.2C6.2 12.5 5.3 10.4 5.3 8S6.2 3.5 8 1.8Z"/></svg>',
  server: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2"><rect x="2" y="2.5" width="12" height="4.5" rx="1.2"/><rect x="2" y="9" width="12" height="4.5" rx="1.2"/><circle cx="4.6" cy="4.75" r=".6" fill="currentColor" stroke="none"/><circle cx="4.6" cy="11.25" r=".6" fill="currentColor" stroke="none"/></svg>',
  share: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2"><path d="M2 5.2a1.4 1.4 0 0 1 1.4-1.4h3l1.3 1.5h4.9A1.4 1.4 0 0 1 14 6.7v4.6a1.4 1.4 0 0 1-1.4 1.4H3.4A1.4 1.4 0 0 1 2 11.3Z"/><path d="M8 7.8v3M6.6 9.3 8 7.8l1.4 1.5"/></svg>',
  folder: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2"><path d="M1.8 4.6a1.3 1.3 0 0 1 1.3-1.3h3.1l1.4 1.6h5.3a1.3 1.3 0 0 1 1.3 1.3v5.9a1.3 1.3 0 0 1-1.3 1.3H3.1a1.3 1.3 0 0 1-1.3-1.3Z"/></svg>',
  tray: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2"><path d="M2 9.2 3.8 3.6A1 1 0 0 1 4.8 3h6.4a1 1 0 0 1 1 .6L14 9.2V12a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1Z"/><path d="M2 9.2h3.3l.9 1.5h3.6l.9-1.5H14"/></svg>',
  home: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M2.5 7.4 8 2.8l5.5 4.6M4 6.3v6.7h3V9.6h2V13h3V6.3"/></svg>',
  chev: '<svg viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.4"><path d="m3.5 1.8 3.2 3.2-3.2 3.2"/></svg>',
  disc: '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.4"><path d="m4.5 2.5 3.5 3.5-3.5 3.5"/></svg>',
  back: '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M7.8 2.2 4 6l3.8 3.8"/></svg>',
  fwd: '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M4.2 2.2 8 6l-3.8 3.8"/></svg>',
  plus: '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M6 1.5v9M1.5 6h9"/></svg>',
  eject: '<svg viewBox="0 0 14 14" fill="currentColor"><path d="M7 2.5 12 8H2Z"/><rect x="2" y="9.5" width="10" height="1.6" rx=".5"/></svg>',
  search: '<svg viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="7.8" cy="7.8" r="5.3"/><path d="m11.8 11.8 4 4"/></svg>',
  sortUp: '<svg viewBox="0 0 8 8" fill="currentColor"><path d="M4 1.5 7 6H1Z"/></svg>',
  sortChev: '<svg viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.4"><path d="m2 6.5 3-3 3 3"/></svg>'
};
function fileIcon(kind) {
  if (kind === "folder") {
    return '<svg class="fi" viewBox="0 0 16 16"><path d="M1 3.6A1.1 1.1 0 0 1 2.1 2.5h3.6l1.3 1.3h6.9A1.1 1.1 0 0 1 15 4.9v7.9a1.1 1.1 0 0 1-1.1 1.1H2.1A1.1 1.1 0 0 1 1 12.8Z" fill="#3E9BE6"/><path d="M1 5.6a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v7.2a1.1 1.1 0 0 1-1.1 1.1H2.1A1.1 1.1 0 0 1 1 12.8Z" fill="#6BB8F2"/><path d="M1 5.6a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v.5H1Z" fill="#8FCBF6"/></svg>';
  }
  const badge = { xlsx: ["#1E8E4E","X"], pdf: ["#D93A2B","PDF"], md: ["#5B6169","MD"], py: ["#3572A5","PY"] }[kind];
  return '<svg class="fi" viewBox="0 0 16 16"><path d="M3.2 1h6.5L13 4.3v10a.9.9 0 0 1-.9.9H3.2a.9.9 0 0 1-.9-.9V1.9a.9.9 0 0 1 .9-.9Z" fill="#FFFFFF" stroke="#BFC3C8" stroke-width=".7"/><path d="M9.7 1v2.6a.7.7 0 0 0 .7.7H13" fill="#E9ECEF" stroke="#BFC3C8" stroke-width=".7"/>' +
    '<rect x="3.6" y="9.3" width="7.6" height="3.6" rx=".9" fill="' + badge[0] + '"/><text x="7.4" y="12.05" text-anchor="middle" font-size="' + (badge[1].length > 2 ? 2.5 : 2.9) + '" font-weight="700" fill="#FFFFFF" font-family="-apple-system, Helvetica, Arial, sans-serif">' + badge[1] + '</text></svg>';
}

const state = { dir: "a", app: "light", acc: "detours", den: "compact", pane: "left", qn: false };
try {
  const t = document.documentElement.getAttribute("data-theme");
  if (t === "dark" || (!t && window.matchMedia("(prefers-color-scheme: dark)").matches)) state.app = "dark";
} catch (e) { /* default stays light */ }

function tabsHTML(d, p) {
  const cls = d === "c" ? "tabs underline" : "tabs";
  let h = '<div class="' + cls + '">';
  p.tabs.forEach(t => {
    h += '<div class="tab' + (t[2] ? " sel" : "") + '">' + G[t[0]] + '<span>' + t[1] + '</span></div>';
  });
  return h + '<div class="tab add" aria-hidden="true">' + G.plus + '</div></div>';
}
function pathHTML(d, p) {
  const nav = '<div class="nav"><b>' + G.back + '</b><b class="off">' + G.fwd + '</b></div>';
  if (d === "c") return '<div class="path mono">' + nav + '<span class="crumb last">' + p.monoPath + '</span></div>';
  let h = '<div class="path">' + nav;
  p.crumbs.forEach((c, i) => {
    const last = i === p.crumbs.length - 1;
    h += '<span class="crumb' + (last ? " last" : "") + '">' + (c[0] ? G[c[0]] : "") + c[1] + '</span>';
    if (!last) h += '<span class="crumb">' + G.chev.replace("<svg", '<svg class="chev"') + '</span>';
  });
  return h + '</div>';
}
function colsHTML(d) {
  const sort = d === "c" ? G.sortUp.replace("<svg", '<svg class="sort"') : G.sortChev.replace("<svg", '<svg class="sort"');
  if (d === "c") return '<div class="cols"><div class="c">Name ' + sort + '</div><div class="c r">Git</div><div class="c r">Size</div><div class="c r">Modified</div><div class="c r">Mode</div></div>';
  return '<div class="cols"><div class="c">Name ' + sort + '</div><div class="c r">Size</div><div class="c r">Date Modified</div></div>';
}
function rowHTML(d, r) {
  const disc = r.k === "folder" ? G.disc.replace("<svg", '<svg class="disc"') : '<svg class="disc blank" viewBox="0 0 12 12"></svg>';
  let gitLead = "", gitTail = "", gitCol = "";
  if (r.g) {
    const label = ' title="' + GIT_NAME[r.g] + '"';
    if (d === "a") gitLead = '<i class="git-bar g-' + r.g + '"' + label + '></i>';
    if (d === "b") gitTail = '<i class="git-dot g-' + r.g + '"' + label + '></i>';
    if (d === "c") gitCol = '<div class="git-l g-' + r.g + '"' + label + '>' + GIT_LETTER[r.g] + '</div>';
  } else if (d === "c") {
    gitCol = '<div></div>';
  }
  const name = '<div class="c nmc">' + (d === "a" && !r.g ? '<i class="git-bar" style="background:transparent"></i>' : gitLead) + disc + fileIcon(r.k) + '<span class="nm">' + r.n + '</span>' + gitTail + '</div>';
  if (d === "c") {
    return '<div class="row' + (r.sel ? " sel" : "") + '">' + name + gitCol + '<div class="r mono">' + r.s + '</div><div class="r mono">' + r.d + '</div><div class="r mono">' + r.m + '</div></div>';
  }
  return '<div class="row' + (r.sel ? " sel" : "") + '">' + name + '<div class="r">' + r.s + '</div><div class="r">' + r.d + '</div></div>';
}
function statusHTML(d, p) {
  const glass = d === "a" ? " glass" : "";
  const parts = p.status.slice();
  let h = '<div class="st' + glass + '">';
  if (p.remote) {
    h += d === "c" ? '<span class="chip"><i class="dot"></i>devtest · connected</span>' : '<span>devtest</span><span class="sep">·</span>';
  }
  h += parts.map(s => '<span>' + s + '</span>').join('<span class="sep">·</span>');
  return h + '</div>';
}
function paneHTML(d, p, active) {
  const glass = d === "a" ? " glass" : "";
  const tint = d === "c" ? " tinted" : "";
  return '<section class="pane ' + (active ? "active" : "inactive") + '">' +
    '<div class="ph' + glass + tint + '">' + tabsHTML(d, p) + pathHTML(d, p) + '</div>' +
    colsHTML(d) + '<div class="list">' + p.rows.map(r => rowHTML(d, r)).join("") + '</div>' + statusHTML(d, p) + '</section>';
}
function sidebarHTML(d) {
  const caps = d === "c" ? " caps" : "";
  const sec = (title, items) => '<div class="sb-sec"><div class="sb-h' + caps + '">' + title + '</div>' + items.join("") + '</div>';
  const it = (g, n, meta, opts) => {
    opts = opts || {};
    return '<div class="sb-i' + (opts.sel ? " sel" : "") + (opts.sub ? " sub" : "") + '">' + (opts.dot ? '<i class="dot"></i>' : G[g]) +
      '<span class="nm">' + n + '</span>' + (meta ? '<span class="meta">' + meta + '</span>' : "") + (opts.ej ? G.eject.replace("<svg", '<svg class="ej"') : "") + '</div>';
  };
  return '<aside class="sb' + (d === "b" ? "" : " glass") + '">' +
    sec("Favorites", [it("tray","INBOX"), it("folder","1 Projects"), it("folder","2 Areas"), it("folder","3 Resources"), it("folder","4 Archive"), it("folder","dev")]) +
    sec("Devices", [it("drive","Macintosh HD","926 GB"), it("disk","Detours.dmg","",{ej:1}), it("disk","Specs.sparsebundle","",{ej:1})]) +
    sec("Remote Hosts", [it(null,"devtest","",{dot:1, ej:1})]) +
    sec("File Servers", [it("server","Acme NAS","SMB",{ej:1}), it("share","Projects","",{sub:1})]) +
    '</aside>';
}
function quickNavHTML(d) {
  const glass = d === "a" ? " glass" : "";
  const cmd = d === "c" ? " cmd" : "";
  const res = [
    ["folder", "<mark>Proj</mark>ects", "~/Projects", "Folder"],
    ["folder", "acme-corp", "~/<mark>Proj</mark>ects/acme-corp", "Folder"],
    ["folder", "taskflow", "~/<mark>Proj</mark>ects/taskflow", "Folder"],
    ["folder", "1 <mark>Proj</mark>ects", "~/1 Projects", "Folder"],
    ["folder", "<mark>Proj</mark>ects", "devtest:/home/maf/Projects", "Remote"]
  ];
  let list = res.map((r, i) => {
    if (d === "c") {
      return '<div class="qn-r' + (i === 0 ? " sel" : "") + '">' + fileIcon(r[0]) + '<div class="t"><b>' + r[1] + '</b></div><div class="loc">' + r[2].replace(/<\/?mark>/g, "") + '</div><div class="k">' + r[3] + '</div></div>';
    }
    return '<div class="qn-r' + (i === 0 ? " sel" : "") + '">' + fileIcon(r[0]) + '<div class="t"><b>' + r[1] + '</b><small>' + r[2].replace(/<\/?mark>/g, "") + '</small></div><div class="k">' + (i === 0 ? "↩" : "⌘" + (i + 1)) + '</div></div>';
  }).join("");
  const foot = d === "c" ? '<div class="qn-foot"><span><kbd>↩</kbd>Open</span><span><kbd>⌘↩</kbd>Open in other pane</span><span><kbd>⌥↩</kbd>Reveal</span></div>' : "";
  return '<div class="qn-veil"></div><div class="qn' + glass + cmd + '"><div class="qn-in">' + G.search + '<span class="q">proj<span class="caret"></span></span><span class="hint">5 matches</span></div><div class="qn-list">' + list + '</div>' + foot + '</div>';
}
function windowHTML(d, app) {
  const leftActive = state.pane === "left";
  return '<div class="scene ' + app + '"><div class="win ' + d + ' ' + app + ' acc-' + state.acc + ' d-' + state.den + '">' +
    '<div class="lights" aria-hidden="true"><i></i><i></i><i></i></div>' + sidebarHTML(d) +
    '<div class="panes">' + paneHTML(d, LEFT, leftActive) + paneHTML(d, RIGHT, !leftActive) + '</div>' +
    (state.qn ? quickNavHTML(d) : "") + '</div></div>';
}
function stageHTML(d, app, label) {
  const name = DIRS[d].name + ", " + app;
  return '<div class="stagebox"' + (label ? "" : "") + '><div class="scaler" role="img" aria-label="' + name + ' mockup">' + windowHTML(d, app) + '</div>' + (label ? '<span class="cap">' + app + '</span>' : "") + '</div>';
}
function iconHTML(d) {
  const set = ICONS[d];
  const bed = app => {
    const src = set[app];
    if (!src || src.indexOf("__") === 0) return '<div class="iconbed ' + app + '"><span class="icon-missing">Icon pending</span></div>';
    return '<div class="iconbed ' + app + '">' + [128, 64, 32].map(s => '<figure><img src="' + src + '" width="' + s + '" height="' + s + '" alt="' + DIRS[d].name + ' icon, ' + app + ', ' + s + ' px"><figcaption>' + s + '</figcaption></figure>').join("") + '</div>';
  };
  return '<div class="icons">' + bed("light") + bed("dark") + '</div>';
}
function viewHTML(d) {
  const apps = state.app === "both" ? ["light", "dark"] : [state.app];
  const info = DIRS[d];
  return '<section class="view"><div class="view-head"><h2>' + info.name + '</h2><span class="tag">' + info.tag + '</span></div>' +
    '<div class="pair' + (apps.length > 1 ? " two" : "") + '">' + apps.map(a => stageHTML(d, a, apps.length > 1)).join("") + '</div>' +
    '<div class="detail"><div class="card"><h3>What defines it</h3><ul>' + info.traits.map(t => '<li>' + t + '</li>').join("") + '</ul><p class="os">' + info.os + '</p></div>' +
    '<div class="card"><h3>Icon</h3><p style="margin:0 0 12px">' + info.icon + '</p>' + iconHTML(d) + '</div></div></section>';
}
function fit() {
  document.querySelectorAll(".scaler").forEach(sc => {
    const w = sc.parentElement.clientWidth;
    const s = w / 1360;
    const scene = sc.firstElementChild;
    scene.style.transform = "scale(" + s + ")";
    sc.style.height = (880 * s) + "px";
  });
}
function render() {
  const dirs = state.dir === "all" ? ["a", "b", "c"] : [state.dir];
  document.getElementById("views").innerHTML = dirs.map(viewHTML).join("");
  [["ctl-dir","dir"],["ctl-app","app"],["ctl-acc","acc"],["ctl-den","den"],["ctl-pane","pane"]].forEach(([id, key]) => {
    document.querySelectorAll("#" + id + " button").forEach(b => b.setAttribute("aria-pressed", String(b.dataset.v === state[key])));
  });
  document.getElementById("ctl-qn").setAttribute("aria-pressed", String(state.qn));
  fit();
}
[["ctl-dir","dir"],["ctl-app","app"],["ctl-acc","acc"],["ctl-den","den"],["ctl-pane","pane"]].forEach(([id, key]) => {
  document.getElementById(id).addEventListener("click", e => {
    const b = e.target.closest("button");
    if (!b) return;
    state[key] = b.dataset.v;
    render();
  });
});
document.getElementById("ctl-qn").addEventListener("click", () => { state.qn = !state.qn; render(); });
window.addEventListener("resize", fit);
render();
