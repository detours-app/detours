function paneState(key) { return state.panes[key]; }
function activeTab(key) {
  const pane = paneState(key);
  return pane.tabs.find(tab => tab.id === pane.activeTab);
}
function pathKey(path) { return path.join("/"); }
function rowsFor(tab) { return contentByPath.get(pathKey(tab.path)) || rows.generic; }
function labelForHost(pane) {
  return pane.remote ? `<span class="dot"></span><span class="host-label">${escapeHtml(pane.host)}</span>` : `<span class="host-label">${escapeHtml(pane.host)}</span>`;
}
function activatePane(key) {
  state.activePane = key;
  render();
}
function pushPath(tab, path) {
  tab.path = [...path];
  tab.history = tab.history.slice(0, tab.historyIndex + 1);
  tab.history.push([...path]);
  tab.historyIndex = tab.history.length - 1;
}
function selectedRow(tab) {
  return rowsFor(tab).find(row => row.name === tab.selected);
}
function render() {
  document.querySelectorAll("[data-source]").forEach(button => {
    const row = button.closest(".mount-row") || button;
    row.classList.toggle("active", button.dataset.source === state.activeSource);
  });
  renderPane("left");
  renderPane("right");
  document.querySelectorAll('.command-strip [data-action="quick-nav"]').forEach(button => {
    button.classList.toggle("active", state.quickNav.open);
  });
  renderQuickNav();
  renderInspector();
}
function renderPane(key) {
  const paneElement = document.querySelector(`.pane[data-pane="${key}"]`);
  const pane = paneState(key);
  const tab = activeTab(key);
  const items = rowsFor(tab);
  paneElement.classList.toggle("inactive", state.activePane !== key);
  paneElement.querySelector('[data-role="host"]').innerHTML = labelForHost(pane);
  renderTabs(paneElement, pane);
  renderPath(paneElement, key, tab);
  renderList(paneElement, key, tab, items);
  renderStatus(paneElement, pane, tab, items);
  paneElement.querySelector('[data-action="back"]').disabled = tab.historyIndex === 0;
  paneElement.querySelector('[data-action="forward"]').disabled = tab.historyIndex >= tab.history.length - 1;
  paneElement.querySelector('[data-action="info"]').classList.toggle("active", tab.info);
}
function renderTabs(paneElement, pane) {
  paneElement.querySelector('[data-role="tabs"]').innerHTML = pane.tabs.map(tab => `
    <button class="tab${tab.id === pane.activeTab ? " selected" : ""}" type="button" data-tab="${tab.id}">
      <span class="folder-icon"></span><span>${escapeHtml(tab.name)}</span>
    </button>
  `).join("");
}
function renderPath(paneElement, paneKey, tab) {
  const path = tab.path.map((part, index) => {
    const current = index === tab.path.length - 1;
    const separator = index === 0 ? "" : '<span class="separator">></span>';
    return `${separator}<button class="crumb${current ? " current" : ""}" type="button" data-crumb="${index}">${escapeHtml(part)}</button>`;
  }).join("");
  paneElement.querySelector('[data-role="path"]').innerHTML = path;
}
function renderList(paneElement, paneKey, tab, items) {
  paneElement.querySelector('[data-role="list"]').innerHTML = items.map(row => {
    const icon = row.type === "folder" ? folderIcon : docIcon;
    const disclosure = row.type === "folder" ? "folder" : "";
    const selected = row.name === tab.selected ? " selected" : "";
    const git = row.git ? " git" : "";
    return `
      <button class="row${selected}${git}" type="button" data-row="${escapeAttr(row.name)}" data-type="${row.type}">
        <div class="name"><span class="disclosure ${disclosure}"></span>${icon}<span>${escapeHtml(row.name)}</span></div>
        <div class="num muted">${escapeHtml(row.size)}</div>
        <div class="muted">${escapeHtml(row.modified)}</div>
      </button>
    `;
  }).join("");
}
function renderStatus(paneElement, pane, tab, items) {
  const selected = selectedRow(tab);
  const label = selected
    ? `1 of ${items.length} selected - ${selected.type === "folder" ? "folder" : selected.size} - ${selected.name}`
    : `${items.length} items`;
  const suffix = tab.info ? " - info" : "";
  paneElement.querySelector('[data-role="status-main"]').textContent = pane.statusOverride || `${label}${suffix}`;
  paneElement.querySelector('[data-role="status-right"]').textContent = pane.meta;
}
function selectRow(paneKey, name) {
  const tab = activeTab(paneKey);
  tab.selected = name;
  activatePane(paneKey);
}
function handleRowClick(paneKey, rowButton) {
  const tab = activeTab(paneKey);
  const name = rowButton.dataset.row;
  const now = performance.now();
  if (rowButton.dataset.type === "folder" && tab.selected === name && tab.lastClickName === name && now - tab.lastClickAt < 700) {
    openSelectedFolder(paneKey);
    return;
  }
  tab.lastClickName = name;
  tab.lastClickAt = now;
  selectRow(paneKey, name);
}
function openSelectedFolder(paneKey) {
  const tab = activeTab(paneKey);
  const row = selectedRow(tab);
  if (!row || row.type !== "folder") return;
  pushPath(tab, [...tab.path, row.name]);
  tab.selected = null;
  render();
}
function navigateHistory(paneKey, delta) {
  const tab = activeTab(paneKey);
  const next = tab.historyIndex + delta;
  if (next < 0 || next >= tab.history.length) return;
  tab.historyIndex = next;
  tab.path = [...tab.history[next]];
  tab.selected = null;
  activatePane(paneKey);
}
function switchTab(paneKey, tabId) {
  paneState(paneKey).activeTab = tabId;
  activatePane(paneKey);
}
function addTab(paneKey) {
  const pane = paneState(paneKey);
  const current = activeTab(paneKey);
  const id = `tab-${Date.now()}-${paneKey}`;
  const label = current.path[current.path.length - 1] || "New Tab";
  pane.tabs.push(makeTab(id, label, current.path, null));
  pane.activeTab = id;
  activatePane(paneKey);
}
function toggleTool(paneKey, tool) {
  const tab = activeTab(paneKey);
  if (tool === "info") {
    tab.info = !tab.info;
    if (tab.info) state.quickNav.open = false;
  }
  activatePane(paneKey);
}
function openQuickNav(paneKey) {
  state.activePane = paneKey;
  activeTab(paneKey).info = false;
  state.quickNav = { open: true, pane: paneKey, query: "" };
  render();
}
function closeQuickNav() {
  state.quickNav.open = false;
  render();
}
function renderQuickNav() {
  const panel = document.querySelector('[data-role="command-panel"]');
  panel.classList.toggle("hidden", !state.quickNav.open);
  if (!state.quickNav.open) return;
  const input = panel.querySelector('[data-role="quick-query"]');
  if (input.value !== state.quickNav.query) input.value = state.quickNav.query;
  renderQuickResults();
  setTimeout(() => {
    if (state.quickNav.open && document.activeElement !== input) {
      input.focus();
      input.select();
    }
  }, 0);
}
function renderQuickResults() {
  const resultsElement = document.querySelector('[data-role="quick-results"]');
  const query = state.quickNav.query.trim().toLowerCase();
  const targets = quickTargets().filter(target => {
    if (!query) return true;
    return `${target.label} ${target.meta}`.toLowerCase().includes(query);
  }).slice(0, 8);
  state.quickNav.results = targets;
  resultsElement.innerHTML = targets.map((target, index) => `
    <button class="command-result${index === 0 ? " active" : ""}" type="button" data-quick-target="${index}">
      ${target.icon === "doc" ? docIcon : folderIcon}
      <span class="result-main">${escapeHtml(target.label)}</span>
      <span class="result-meta">${escapeHtml(target.meta)}</span>
    </button>
  `).join("");
}
function quickTargets() {
  const paneKey = state.quickNav.pane;
  const tab = activeTab(paneKey);
  const selected = selectedRow(tab);
  const localRows = rowsFor(tab).map(row => ({
    label: row.name,
    meta: row.type === "folder" ? "current folder" : "current file",
    pane: paneKey,
    path: row.type === "folder" ? [...tab.path, row.name] : [...tab.path],
    selected: row.type === "folder" ? null : row.name,
    icon: row.type === "folder" ? "folder" : "doc"
  }));
  return [
    selected ? {
      label: selected.type === "folder" ? `Open ${selected.name}` : `Reveal ${selected.name}`,
      meta: "active selection",
      pane: paneKey,
      path: selected.type === "folder" ? [...tab.path, selected.name] : [...tab.path],
      selected: selected.type === "folder" ? null : selected.name,
      icon: selected.type === "folder" ? "folder" : "doc"
    } : null,
    ...localRows,
    { label: "cognel-dev-next specs", meta: "remote host", source: "cognel", pane: "right", path: ["opt", "cognel-app", "resources", "specs"], selected: "cognel-v3-05-fullapp-prototype.evidence" },
    { label: "Specs.sparsebundle", meta: "mounted sparse bundle", source: "sparsebundle", pane: "left", path: ["Volumes", "Specs.sparsebundle"] },
    { label: "Detours.dmg", meta: "mounted disk image", source: "diskimage", pane: "left", path: ["Volumes", "Detours.dmg"] },
    { label: "Detours repo resources", meta: "local navigation", pane: "left", path: ["Users", "marco", "dev", "detours", "resources"], selected: "specs" },
    { label: "foundry detours", meta: "remote host", source: "foundry", pane: "right", path: ["home", "marco", "dev", "detours"], selected: "detours" },
    { label: "Acme NAS", meta: "file server", source: "nas", pane: "left", path: ["Volumes", "Acme NAS"] }
  ].filter(Boolean);
}
function applyQuickTarget(index) {
  const target = state.quickNav.results[index];
  if (!target) return;
  if (target.source) applySource(target.source);
  const paneKey = target.pane || state.quickNav.pane;
  const tab = activeTab(paneKey);
  tab.path = [...target.path];
  tab.selected = target.selected || null;
  tab.history = [[...target.path]];
  tab.historyIndex = 0;
  state.activePane = paneKey;
  state.quickNav.open = false;
  render();
}
function renderInspector() {
  const panel = document.querySelector('[data-role="inspector-panel"]');
  const paneKey = state.activePane;
  const pane = paneState(paneKey);
  const tab = activeTab(paneKey);
  const selected = selectedRow(tab);
  panel.classList.toggle("left", paneKey === "left");
  panel.classList.toggle("right", paneKey === "right");
  panel.classList.toggle("hidden", !tab.info);
  if (!tab.info) return;
  const fullPath = selected ? [...tab.path, selected.name] : tab.path;
  const kind = selected ? selected.type : "folder";
  const name = selected ? selected.name : tab.path[tab.path.length - 1];
  const context = pane.remote ? "remote SSH" : pane.meta === "sparsebundle" ? "mounted sparse bundle" : pane.meta === "disk image" ? "mounted disk image" : pane.meta;
  panel.querySelector('[data-role="inspector-body"]').innerHTML = `
    <div class="inspector-title">${escapeHtml(name)}</div>
    <div class="inspector-grid">
      <span class="key">Kind</span><span class="value">${escapeHtml(kind)}</span>
      <span class="key">Host</span><span class="value">${escapeHtml(pane.host)}</span>
      <span class="key">Context</span><span class="value">${escapeHtml(context)}</span>
      <span class="key">Path</span><span class="value">${escapeHtml(fullPath.join("/"))}</span>
      <span class="key">Size</span><span class="value">${escapeHtml(selected?.size || "-")}</span>
      <span class="key">Modified</span><span class="value">${escapeHtml(selected?.modified || "current folder")}</span>
    </div>
  `;
}
function goToCrumb(paneKey, index) {
  const tab = activeTab(paneKey);
  const nextPath = tab.path.slice(0, index + 1);
  pushPath(tab, nextPath);
  tab.selected = null;
  activatePane(paneKey);
}
function applySource(source) {
  state.activeSource = source;
  state.panes.left.statusOverride = "";
  state.panes.right.statusOverride = "";
  if (source === "cognel") {
    state.panes.right.host = "cognel-dev-next";
    state.panes.right.meta = "ssh 18 ms";
    state.panes.right.remote = true;
    if (!state.panes.right.tabs.some(tab => tab.id === "cognel-app")) {
      state.panes.right.tabs = [
        makeTab("opt", "opt", ["opt"], "cognel-app"),
        makeTab("cognel-app", "cognel-app", ["opt", "cognel-app", "resources", "specs"], "cognel-v3-05-fullapp-prototype.evidence")
      ];
    }
    state.panes.right.activeTab = "cognel-app";
    state.activePane = "right";
  } else if (source === "foundry") {
    state.panes.right.host = "foundry";
    state.panes.right.meta = "ssh idle";
    state.panes.right.remote = true;
    const tab = makeTab("foundry-tab", "foundry", ["home", "marco", "dev", "detours"], "detours");
    state.panes.right.tabs = [tab];
    state.panes.right.activeTab = tab.id;
    state.activePane = "right";
  } else {
    const sourceTargets = {
      macintosh: { path: ["Users", "marco"], host: "Local", meta: "local" },
      sparsebundle: { path: ["Volumes", "Specs.sparsebundle"], host: "Mounted", meta: "sparsebundle" },
      diskimage: { path: ["Volumes", "Detours.dmg"], host: "Mounted", meta: "disk image" },
      nas: { path: ["Volumes", "Acme NAS"], host: "Acme NAS", meta: "smb" },
      projects: { path: ["Users", "marco", "1 Projects"], host: "Local", meta: "local" },
      inbox: { path: ["Users", "marco", "INBOX"], host: "Local", meta: "local" },
      "one-projects": { path: ["Users", "marco", "1 Projects"], host: "Local", meta: "local" },
      "two-areas": { path: ["Users", "marco", "2 Areas"], host: "Local", meta: "local" },
      dev: { path: ["Users", "marco", "dev"], host: "Local", meta: "local" }
    };
    const target = sourceTargets[source] || sourceTargets.macintosh;
    const path = target.path;
    const id = `source-${source}`;
    const label = path[path.length - 1];
    state.panes.left.host = target.host;
    state.panes.left.meta = target.meta;
    state.panes.left.remote = false;
    const existing = state.panes.left.tabs.find(tab => tab.id === id);
    if (existing) {
      state.panes.left.activeTab = id;
    } else {
      state.panes.left.tabs.push(makeTab(id, label, path, null));
      state.panes.left.activeTab = id;
    }
    state.activePane = "left";
  }
  render();
}
function ejectSource(source) {
  const labels = {
    sparsebundle: "Specs.sparsebundle",
    diskimage: "Detours.dmg"
  };
  applySource(source);
  state.panes.left.statusOverride = `Eject ${labels[source] || "volume"} from Devices`;
  render();
}
function moveSelection(delta) {
  const tab = activeTab(state.activePane);
  const items = rowsFor(tab);
  const currentIndex = Math.max(0, items.findIndex(row => row.name === tab.selected));
  const nextIndex = Math.min(items.length - 1, Math.max(0, currentIndex + delta));
  tab.selected = items[nextIndex].name;
  render();
}
function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[char]));
}
function escapeAttr(value) { return escapeHtml(value); }

document.addEventListener("click", event => {
  const paneElement = event.target.closest(".pane");
  if (paneElement) state.activePane = paneElement.dataset.pane;
  const eject = event.target.closest("[data-eject]");
  if (eject) {
    event.preventDefault();
    event.stopPropagation();
    return ejectSource(eject.dataset.eject);
  }
  const quickTarget = event.target.closest("[data-quick-target]");
  if (quickTarget) return applyQuickTarget(Number(quickTarget.dataset.quickTarget));
  const source = event.target.closest("[data-source]");
  if (source) return applySource(source.dataset.source);
  const tabButton = event.target.closest("[data-tab]");
  if (tabButton) return switchTab(state.activePane, tabButton.dataset.tab);
  const rowButton = event.target.closest("[data-row]");
  if (rowButton) return handleRowClick(state.activePane, rowButton);
  const crumb = event.target.closest("[data-crumb]");
  if (crumb) return goToCrumb(state.activePane, Number(crumb.dataset.crumb));
  const action = event.target.closest("[data-action]");
  if (!action) return;
  const paneKey = action.closest(".pane")?.dataset.pane || state.activePane;
  if (action.dataset.action === "back") navigateHistory(paneKey, -1);
  if (action.dataset.action === "forward") navigateHistory(paneKey, 1);
  if (action.dataset.action === "new-tab") addTab(paneKey);
  if (action.dataset.action === "quick-nav") openQuickNav(paneKey);
  if (action.dataset.action === "info") toggleTool(paneKey, "info");
  if (action.dataset.action === "close-command") closeQuickNav();
  if (action.dataset.action === "close-info") {
    activeTab(state.activePane).info = false;
    render();
  }
});

document.addEventListener("input", event => {
  if (!event.target.matches('[data-role="quick-query"]')) return;
  state.quickNav.query = event.target.value;
  renderQuickResults();
});

document.addEventListener("dblclick", event => {
  const rowButton = event.target.closest("[data-row]");
  if (rowButton && rowButton.dataset.type === "folder") {
    const paneKey = rowButton.closest(".pane")?.dataset.pane || state.activePane;
    selectRow(paneKey, rowButton.dataset.row);
    openSelectedFolder(paneKey);
  }
});

document.addEventListener("keydown", event => {
  if (state.quickNav.open && event.key === "Escape") {
    event.preventDefault();
    closeQuickNav();
    return;
  }
  if (state.quickNav.open && event.key === "Enter" && event.target.matches('[data-role="quick-query"]')) {
    event.preventDefault();
    applyQuickTarget(0);
    return;
  }
  if (event.key === "ArrowDown") { event.preventDefault(); moveSelection(1); }
  if (event.key === "ArrowUp") { event.preventDefault(); moveSelection(-1); }
  if (event.key === "Enter") { event.preventDefault(); openSelectedFolder(state.activePane); }
  if (event.key === "Backspace") { event.preventDefault(); navigateHistory(state.activePane, -1); }
});

render();
