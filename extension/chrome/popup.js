const CONFIG = "~/.config/clipb.toml";
const body = document.getElementById("body");
const statusText = document.getElementById("statusText");
const pauseButton = document.getElementById("pause");

// The routing row can change while the popup stays open, so it renders on its own.
function renderPause(paused) {
  statusText.textContent = paused ? "Paused — links stay here" : "On — matching links move";
  pauseButton.textContent = paused ? "Resume routing" : "Pause routing";
}

pauseButton.addEventListener("click", async () => {
  // One toggle per click: a second click would race the first reply.
  pauseButton.disabled = true;
  let paused;
  try {
    paused = await chrome.runtime.sendMessage({ op: "togglePause" });
  } catch {
    statusText.textContent = "Couldn't change routing. Try again.";
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
  const { arrived = {}, sent = {}, error, paused = false } = await chrome.storage.session.get(["arrived", "sent", "error", "paused"]);
  const here = tab && arrived[tab.id];
  const away = tab && sent[tab.id];
  const title = document.getElementById("titleText");
  let config = CONFIG;
  let note = null;
  let state = paused ? "paused" : "active";

  if (here) {
    state = "moved";
    title.textContent = "Redirected to this profile";
    row("Link", short(here.url));
    row("From profile", here.from);
    row("Rule", here.rule || "(not recorded)", true);
    row("Why", "A rule in your config sends links like this one to this profile, so ClipB opened it here.");
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
    title.textContent = "Redirected to another profile";
    row("Link", short(away.url));
    row("To profile", away.to);
    row("Rule", away.rule || "(not recorded)", true);
    line("This tab stayed.");
  } else if (paused) {
    title.textContent = "Routing paused — links stay in this profile";
    line("Resume routing to move matches.");
  } else {
    title.textContent = "No rule matched this page";
  }

  document.body.className = state;
  renderPause(paused);

  document.getElementById("note").textContent =
    (note || `Rules live in ${config}. Edit that file and the next link uses the change.`) +
    ` · v${chrome.runtime.getManifest().version}`;
})();
