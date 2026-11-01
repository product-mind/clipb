const CONFIG = "~/.config/clipb.toml";
const body = document.getElementById("body");
const noteText = document.getElementById("noteText");
const versionTag = document.getElementById("versionTag");
const pauseButton = document.getElementById("pause");

// The routing row can change while the popup stays open, so it renders on its own.
function renderPause(paused) {
  pauseButton.textContent = paused ? "Resume" : "Pause";
}

pauseButton.addEventListener("click", async () => {
  // One toggle per click: a second click would race the first reply.
  pauseButton.disabled = true;
  let paused;
  try {
    paused = await chrome.runtime.sendMessage({ op: "togglePause" });
  } catch {
    noteText.textContent = "Couldn't change routing. Try again.";
    return;
  } finally {
    pauseButton.disabled = false;
  }
  renderPause(paused);
  const state = document.body.className;
  if (state === "active" || state === "paused") document.body.className = paused ? "paused" : "active";
});

function row(label, value, mono = false) {
  const p = document.createElement("p");
  const b = document.createElement("b");
  b.textContent = `${label} `;
  let v = document.createTextNode(value);
  if (mono) {
    v = document.createElement("code");
    v.textContent = value;
  }
  p.append(b, v);
  body.append(p);
}

function line(text) {
  const p = document.createElement("p");
  p.textContent = text;
  body.append(p);
}

// The rule exactly as written in the config, and the profile it sends to.
function ruleLine(pattern, profile) {
  const p = document.createElement("p");
  const code = document.createElement("code");
  code.textContent = `"${pattern || "(not recorded)"}" = "${profile}"`;
  p.append(code);
  body.append(p);
}

// Host and path only: query strings can carry tokens.
function short(url) {
  try {
    const u = new URL(url);
    return u.host + (u.pathname === "/" ? "" : u.pathname);
  } catch {
    return url;
  }
}

(async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const { error, paused = false } = await chrome.storage.session.get(["error", "paused"]);
  const { arrived = {}, sent = {}, boot } = await chrome.storage.local.get(["arrived", "sent", "boot"]);
  const here = tab && liveRecord(arrived[tab.id], boot) ? arrived[tab.id] : null;
  const away = tab && liveRecord(sent[tab.id], boot) ? sent[tab.id] : null;
  const title = document.getElementById("titleText");
  let config = CONFIG;
  let note = null;
  let state = paused ? "paused" : "active";

  if (here) {
    state = "moved";
    title.textContent = `Moved from "${here.from}" profile`;
    line(short(here.url));
    line("matched rule:");
    ruleLine(here.rule, here.target);
    config = here.config || CONFIG;
  } else if (error) {
    state = "error";
    title.textContent = "Couldn't redirect — this page stayed";
    if (error.url) row("Link", short(error.url));
    row("Cause", error.message);
    note = String(error.message).includes("install-native-host")
      ? "Run clipb install-native-host, then click the link again."
      : "Fix the cause above, then click the link again.";
    chrome.runtime.sendMessage("ack").catch(() => {});
  } else if (away) {
    state = "sent";
    title.textContent = `Moved to "${away.to}" profile`;
    line(short(away.url));
    line("matched rule:");
    ruleLine(away.rule, away.to);
  } else if (paused) {
    title.textContent = "Paused — links stay in this profile";
    line("Resume routing to move matches.");
  } else {
    title.textContent = "No rule matched this page";
  }

  document.body.className = state;
  renderPause(paused);

  noteText.textContent = note || `See ${config}`;
  versionTag.textContent = `ClipB · v${chrome.runtime.getManifest().version}`;
})();
