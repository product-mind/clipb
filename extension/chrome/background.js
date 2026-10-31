// ClipB Router: moves a tab to the Chrome profile the ClipB rules pick.
// Rules live in ~/.config/clipb.toml; the native host (`clipb`) evaluates them.
const HOST = "com.productmind.clipb";
// Only navigations the user started; redirects and form posts are left alone so
// login flows (OAuth, SSO) are never bounced between profiles.
const USER_TRANSITIONS = new Set(["link", "typed", "generated", "keyword", "keyword_generated"]);
const COLORS = { active: "#188038", paused: "#9aa0a6", sent: "#1a73e8", error: "#d93025" };

// The dot is the routing state (active green / paused grey / error red); arrows mark per-tab events.
// The direction repeats the color: left = arrived here, right = sent away.
function drawIcon(color, arrow, left = false) {
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
      const tail = left ? 0.75 : 0.25;
      const tip = left ? 0.26 : 0.74;
      const barb = left ? 0.48 : 0.52;
      g.beginPath();
      g.moveTo(size * tail, size * 0.5);
      g.lineTo(size * tip, size * 0.5);
      g.moveTo(size * barb, size * 0.28);
      g.lineTo(size * tip, size * 0.5);
      g.lineTo(size * barb, size * 0.72);
      g.stroke();
    }
    images[size] = g.getImageData(0, 0, size, size);
  }
  return images;
}

// Default icon for every tab. A failure turns it red until the popup is opened.
async function paintDefault() {
  const { error, paused } = await chrome.storage.session.get(["error", "paused"]);
  chrome.action.setIcon({ imageData: drawIcon(error ? COLORS.error : paused ? COLORS.paused : COLORS.active, Boolean(error)) });
  chrome.action.setTitle({
    title: error
      ? `ClipB Router: ${error.message}`
      : paused
        ? "ClipB Router (paused — links stay put)"
        : "ClipB Router — on. Matching links open in another profile. Click to pause.",
  });
}

async function fail(message, url) {
  await chrome.storage.session.set({ error: { message, url, time: Date.now() } });
  paintDefault();
}

// Pause is global and session-scoped: a browser restart resumes routing.
async function togglePause() {
  const { paused = false } = await chrome.storage.session.get("paused");
  await chrome.storage.session.set({ paused: !paused });
  await paintDefault();
  return !paused;
}

// The popup sends "ack" once it has shown the failure, or {op: "togglePause"}.
chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg === "ack") {
    chrome.storage.session.remove("error").then(paintDefault);
    return;
  }
  if (msg?.op === "togglePause") {
    togglePause().then(reply);
    return true; // the reply arrives asynchronously
  }
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
  chrome.action.setIcon({ tabId: d.tabId, imageData: drawIcon(COLORS.active, true, true) });
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

// Chrome resets per-tab icons on navigation, so a send is painted once the back commit lands.
// That first commit is the landing itself: a programmatic goBack carries no forward_back
// qualifier. Only then does any later commit mean the tab moved on.
async function paintSent(tabId, qualifiers) {
  const { sent = {} } = await chrome.storage.session.get("sent");
  const record = sent[tabId];
  if (!record) return;
  if (record.pending) {
    // A redirect commit is the site bouncing the original navigation, not the tab moving on.
    if (qualifiers.some((x) => x.endsWith("_redirect"))) {
      console.debug("paintSent", tabId, "waiting (redirect)", qualifiers);
      return;
    }
    record.pending = false;
    await chrome.storage.session.set({ sent });
    console.debug("paintSent", tabId, "painted", record.to, qualifiers);
    // Keep the record: the popup reads it while the tab rests back on its page.
    chrome.action.setIcon({ tabId, imageData: drawIcon(COLORS.sent, true) });
    chrome.action.setTitle({ tabId, title: `ClipB Router: redirected to profile ${record.to} — this tab stayed (click for details)` });
    return;
  }
  console.debug("paintSent", tabId, "cleared (tab moved on)", qualifiers);
  delete sent[tabId];
  await chrome.storage.session.set({ sent });
}

chrome.tabs.onRemoved.addListener(async (tabId) => {
  const { tabs = {}, arrived = {}, sent = {} } = await chrome.storage.session.get(["tabs", "arrived", "sent"]);
  delete tabs[tabId];
  delete arrived[tabId];
  delete sent[tabId];
  await chrome.storage.session.set({ tabs, arrived, sent });
});

chrome.runtime.onInstalled.addListener(markAllTabsSeen);
chrome.runtime.onStartup.addListener(markAllTabsSeen);
paintDefault();

// Reloads the unpacked extension after a version bump; session state (pause, sent, arrived) resets.
chrome.commands.onCommand.addListener((command) => {
  if (command === "reload-extension") chrome.runtime.reload();
});

chrome.webNavigation.onCommitted.addListener(async (d) => {
  if (d.frameId !== 0 || !/^https?:/.test(d.url)) return;
  console.debug("commit", d.tabId, d.transitionType, d.transitionQualifiers);
  const hadPage = await markSeen(d.tabId);

  // A fresh tab may be one ClipB just opened for us; then there is nothing to decide.
  if (!hadPage && (await markArrival(d))) return;

  await paintSent(d.tabId, d.transitionQualifiers);

  // Pause stops the decide below; an arrival above still gets marked.
  const { paused } = await chrome.storage.session.get("paused");
  if (paused) return;

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
  const { sent = {} } = await chrome.storage.session.get("sent");
  sent[d.tabId] = { url: d.url, to: decision.target, rule: decision.rule, pending: true };
  await chrome.storage.session.set({ sent });
  // Only after ClipB took the link, so a failure never loses the page.
  if (!hadPage) {
    chrome.tabs.remove(d.tabId);
    return;
  }
  try {
    await chrome.tabs.goBack(d.tabId);
  } catch {
    delete sent[d.tabId];
    await chrome.storage.session.set({ sent });
  }
});
