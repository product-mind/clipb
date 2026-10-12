// ClipB Router: moves a tab to the Chrome profile the ClipB rules pick.
// Rules live in ~/.config/clipb.toml; the native host (`clipb`) evaluates them.
const HOST = "com.productmind.clipb";
// Only navigations the user started; redirects and form posts are left alone so
// login flows (OAuth, SSO) are never bounced between profiles.
const USER_TRANSITIONS = new Set(["link", "typed", "generated", "keyword", "keyword_generated"]);
const COLORS = { idle: "#9aa0a6", redirected: "#188038", error: "#d93025" };

// Idle is a plain quiet dot. The arrow only appears when something happened.
function drawIcon(color, arrow) {
  const images = {};
  for (const size of [16, 32]) {
    const canvas = new OffscreenCanvas(size, size);
    const g = canvas.getContext("2d");
    g.fillStyle = color;
    g.beginPath();
    g.arc(size / 2, size / 2, arrow ? size / 2 : size * 0.22, 0, Math.PI * 2);
    g.fill();
    if (arrow) {
      g.strokeStyle = "#fff";
      g.lineWidth = size / 8;
      g.lineCap = "round";
      g.lineJoin = "round";
      g.beginPath();
      g.moveTo(size * 0.25, size * 0.5);
      g.lineTo(size * 0.74, size * 0.5);
      g.moveTo(size * 0.52, size * 0.28);
      g.lineTo(size * 0.74, size * 0.5);
      g.lineTo(size * 0.52, size * 0.72);
      g.stroke();
    }
    images[size] = g.getImageData(0, 0, size, size);
  }
  return images;
}

// Default icon for every tab. A failure turns it red until the popup is opened.
async function paintDefault() {
  const { error } = await chrome.storage.session.get("error");
  chrome.action.setIcon({ imageData: drawIcon(error ? COLORS.error : COLORS.idle, Boolean(error)) });
  chrome.action.setTitle({ title: error ? `ClipB Router: ${error.message}` : "ClipB Router" });
}

async function fail(message, url) {
  await chrome.storage.session.set({ error: { message, url, time: Date.now() } });
  paintDefault();
}

// The popup sends this once it has shown the failure.
chrome.runtime.onMessage.addListener((msg) => {
  if (msg === "ack") chrome.storage.session.remove("error").then(paintDefault);
});

// Green icon on the one tab ClipB redirected here; Chrome resets it when the tab navigates.
async function markArrival(d) {
  let reply;
  try {
    reply = await chrome.runtime.sendNativeMessage(HOST, { op: "arrived", url: d.url });
  } catch {
    return false;
  }
  if (!reply?.ok || !reply.from) return false;

  const { arrived = {} } = await chrome.storage.session.get("arrived");
  arrived[d.tabId] = { url: d.url, from: reply.from, target: reply.target, rule: reply.rule, config: reply.config };
  await chrome.storage.session.set({ arrived });
  chrome.action.setIcon({ tabId: d.tabId, imageData: drawIcon(COLORS.redirected, true) });
  chrome.action.setTitle({ tabId: d.tabId, title: `ClipB Router: redirected here from ${reply.from} (click for details)` });
  return true;
}

// Remembers which tabs already showed a page, to tell a fresh tab (close it)
// from a tab that navigated away from a page (go back to that page).
async function markSeen(tabId) {
  const { tabs = {} } = await chrome.storage.session.get("tabs");
  const had = tabs[tabId] === true;
  tabs[tabId] = true;
  await chrome.storage.session.set({ tabs });
  return had;
}

async function markAllTabsSeen() {
  const { tabs = {} } = await chrome.storage.session.get("tabs");
  for (const tab of await chrome.tabs.query({})) tabs[tab.id] = true;
  await chrome.storage.session.set({ tabs });
}

chrome.tabs.onRemoved.addListener(async (tabId) => {
  const { tabs = {}, arrived = {} } = await chrome.storage.session.get(["tabs", "arrived"]);
  delete tabs[tabId];
  delete arrived[tabId];
  await chrome.storage.session.set({ tabs, arrived });
});

chrome.runtime.onInstalled.addListener(markAllTabsSeen);
chrome.runtime.onStartup.addListener(markAllTabsSeen);
paintDefault();

chrome.webNavigation.onCommitted.addListener(async (d) => {
  if (d.frameId !== 0 || !/^https?:/.test(d.url)) return;
  const hadPage = await markSeen(d.tabId);

  // A fresh tab may be one ClipB just opened for us; then there is nothing to decide.
  if (!hadPage && (await markArrival(d))) return;

  const q = d.transitionQualifiers;
  if (!USER_TRANSITIONS.has(d.transitionType) || q.includes("forward_back") || q.some((x) => x.endsWith("_redirect"))) return;

  const tab = await chrome.tabs.get(d.tabId);
  if ((await chrome.windows.get(tab.windowId)).type !== "normal") return;

  const { email } = await chrome.identity.getProfileUserInfo({ accountStatus: "ANY" });
  let decision;
  try {
    decision = await chrome.runtime.sendNativeMessage(HOST, { op: "decide", url: d.url, email });
  } catch (e) {
    return fail(`native host unreachable (run: clipb install-native-host): ${e.message}`, d.url);
  }
  if (!decision.ok) return fail(`host error: ${decision.error}`, d.url);
  if (!decision.move) return;

  const opened = await chrome.runtime.sendNativeMessage(HOST, {
    op: "open", url: d.url, email, target: decision.target, rule: decision.rule,
  });
  if (!opened.ok) return fail(`open failed: ${opened.error}`, d.url);
  // Only after ClipB took the link, so a failure never loses the page.
  if (hadPage) chrome.tabs.goBack(d.tabId);
  else chrome.tabs.remove(d.tabId);
});
