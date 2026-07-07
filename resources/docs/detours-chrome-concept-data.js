const folderIcon = '<span class="folder-icon"></span>';
const docIcon = '<span class="doc-icon"></span>';

function folder(name, size, modified) { return { type: "folder", name, size, modified }; }
function file(name, size, modified, git = false) { return { type: "file", name, size, modified, git }; }
function makeTab(id, name, path, selected) {
  return { id, name, path: [...path], selected, info: false, history: [[...path]], historyIndex: 0 };
}

const rows = {
  detours: [
    folder("src", "-", "Today 14:47"),
    folder("Tests", "-", "Today 14:47"),
    folder("resources", "-", "Today 14:44"),
    file("README.md", "7.3 KB", "27 Jun"),
    file("Package.swift", "2.6 KB", "16 Jun")
  ],
  resources: [
    folder("docs", "-", "Today 13:24"),
    folder("logs", "-", "27 Jun 15:43"),
    folder("migrations", "-", "6 Jul 7:09"),
    folder("scripts", "-", "6 Jul 7:09"),
    folder("specs", "-", "Today 14:29"),
    file("CHANGELOG.md", "3.4 KB", "6 Jul 7:09")
  ],
  localSpecs: [
    folder("done", "-", "Today 13:29"),
    file("detours-v2-12-chrome-polish.md", "18.8 KB", "Today 13:02", true),
    file("detours-v2-13-remote-folders.md", "14.2 KB", "Today 13:11"),
    file("detours-v2-14-release-notes.md", "9.1 KB", "Yesterday")
  ],
  tools: [
    folder("bin", "-", "Today 11:04"),
    folder("scripts", "-", "Today 9:41"),
    file("agent-browser", "22.4 MB", "Today 10:12"),
    file("build-helper", "740 KB", "4 Jul")
  ],
  remoteSpecs: [
    folder("done", "-", "7 Jul 13:29"),
    folder("cognel-v3-05-fullapp-prototype.evidence", "-", "6 Jul 16:08"),
    folder("cognel-v3-05-fullapp-prototype.design-handoff", "-", "7 Jul 14:29"),
    file("cognel-v3-04-scenario-map.md", "31.7 KB", "7 Jul 13:19", true),
    file("cognel-v3-05-fullapp-prototype.md", "35.5 KB", "7 Jul 13:16"),
    file("cognel-v3-07-guide-builder.md", "27.5 KB", "7 Jul 13:22")
  ],
  remoteDone: [
    file("cognel-v3-01-data-contracts.md", "21.0 KB", "4 Jul"),
    file("cognel-v3-02-dashboard.md", "28.8 KB", "5 Jul"),
    file("cognel-v3-03-editor-flow.md", "24.4 KB", "6 Jul"),
    file("cognel-v3-04-scenario-map.md", "31.7 KB", "7 Jul")
  ],
  evidence: [
    file("viewport-desktop.png", "1.2 MB", "6 Jul 16:06"),
    file("viewport-mobile.png", "824 KB", "6 Jul 16:07"),
    file("interaction-log.json", "46 KB", "6 Jul 16:08"),
    file("notes.md", "5.1 KB", "6 Jul 16:08")
  ],
  handoff: [
    file("component-map.md", "12.1 KB", "7 Jul 14:21"),
    file("token-audit.md", "8.8 KB", "7 Jul 14:24"),
    file("handoff-checklist.md", "6.2 KB", "7 Jul 14:29")
  ],
  opt: [
    folder("cognel-app", "-", "6 Jul 16:39"),
    folder("deploy", "-", "27 Jun 12:02"),
    folder("shared", "-", "18 Jun 9:18")
  ],
  foundry: [
    folder("detours", "-", "Today 12:33"),
    folder("screenshots", "-", "Today 12:49"),
    file("build.log", "89 KB", "Today 12:52")
  ],
  sparsebundle: [
    folder("bands", "-", "Today 9:14"),
    folder("snapshots", "-", "Today 9:16"),
    file("Info.plist", "1.7 KB", "Today 9:12"),
    file("token", "8 bytes", "Today 9:12")
  ],
  diskimage: [
    folder("Applications", "-", "Today 8:03"),
    file("Detours.app", "42.8 MB", "Today 8:03"),
    file("README.txt", "3.2 KB", "Today 8:03")
  ],
  generic: [
    folder("archive", "-", "Today 8:32"),
    folder("drafts", "-", "Yesterday"),
    file("README.md", "4.8 KB", "Yesterday"),
    file("notes.md", "2.1 KB", "3 Jul")
  ]
};

const contentByPath = new Map([
  ["Users/marco/dev/detours", rows.detours],
  ["Users/marco/dev/detours/resources", rows.resources],
  ["Users/marco/dev/detours/resources/specs", rows.localSpecs],
  ["Users/marco/Tools", rows.tools],
  ["opt", rows.opt],
  ["opt/cognel-app/resources/specs", rows.remoteSpecs],
  ["opt/cognel-app/resources/specs/done", rows.remoteDone],
  ["opt/cognel-app/resources/specs/cognel-v3-05-fullapp-prototype.evidence", rows.evidence],
  ["opt/cognel-app/resources/specs/cognel-v3-05-fullapp-prototype.design-handoff", rows.handoff],
  ["home/marco/dev/detours", rows.foundry],
  ["Users/marco/dev", rows.detours],
  ["Users/marco/INBOX", rows.generic],
  ["Users/marco/1 Projects", rows.generic],
  ["Users/marco/2 Areas", rows.generic],
  ["Volumes/Acme NAS", rows.generic],
  ["Volumes/Specs.sparsebundle", rows.sparsebundle],
  ["Volumes/Detours.dmg", rows.diskimage]
]);

const state = {
  activePane: "right",
  activeSource: "cognel",
  quickNav: { open: false, pane: "right", query: "" },
  panes: {
    left: {
      host: "Local",
      meta: "local",
      remote: false,
      statusOverride: "",
      activeTab: "detours",
      tabs: [
        makeTab("tools", "Tools", ["Users", "marco", "Tools"], "bin"),
        makeTab("detours", "detours", ["Users", "marco", "dev", "detours"], "resources")
      ]
    },
    right: {
      host: "cognel-dev-next",
      meta: "ssh 18 ms",
      remote: true,
      statusOverride: "",
      activeTab: "cognel-app",
      tabs: [
        makeTab("opt", "opt", ["opt"], "cognel-app"),
        makeTab("cognel-app", "cognel-app", ["opt", "cognel-app", "resources", "specs"], "cognel-v3-05-fullapp-prototype.evidence")
      ]
    }
  }
};
