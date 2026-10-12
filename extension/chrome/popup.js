const CONFIG = "~/.config/clipb.toml";
const body = document.getElementById("body");

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
  const { arrived = {}, error } = await chrome.storage.session.get(["arrived", "error"]);
  const here = tab && arrived[tab.id];
  const title = document.getElementById("titleText");
  let config = CONFIG;

  if (here) {
    document.body.className = "moved";
    title.textContent = "Redirected to this profile";
    row("Link", short(here.url));
    row("From", here.from);
    row("Rule", here.rule || "(not recorded)", true);
    row("Why", "A rule in your config sends links like this one to this profile, so ClipB opened it here.");
    config = here.config || CONFIG;
  } else if (error) {
    document.body.className = "error";
    title.textContent = "Couldn't redirect";
    if (error.url) row("Link", short(error.url));
    row("Cause", error.message);
    chrome.runtime.sendMessage("ack").catch(() => {});
  } else {
    title.textContent = "Nothing redirected on this page";
  }

  document.getElementById("note").textContent =
    `Rules live in ${config}. Edit that file and the next link uses the change.`;
})();
