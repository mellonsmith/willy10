// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

// Hooks for persisting player data in localStorage.
// Sessions are stored per lobby: one JSON entry under "willy:<CODE>", so the
// same browser can hold different identities in different lobbies.
//
// A per-tab flag in sessionStorage decides whether a session is restored
// silently: only a tab that already joined this lobby (reload, LiveView
// reconnect) auto-rejoins. Opening the invite link in a fresh tab always
// shows the join/rejoin screen first, even if another tab of the same
// browser holds the host session.
let Hooks = {};

const sessionKey = (code) => `willy:${code}`;
const tabJoinedKey = (code) => `willy:tab:${code}`;

const markTabJoined = (code) => sessionStorage.setItem(tabJoinedKey(code), "1");
const tabJoined = (code) => sessionStorage.getItem(tabJoinedKey(code)) === "1";

const readSession = (code) => {
  try {
    return JSON.parse(localStorage.getItem(sessionKey(code)));
  } catch {
    localStorage.removeItem(sessionKey(code));
    return null;
  }
};

const writeSession = (code, data) => {
  localStorage.setItem(
    sessionKey(code),
    JSON.stringify({
      player_id: data.player_id,
      nickname: data.nickname,
      role: data.role,
      saved_at: Date.now(),
    }),
  );
};

// Drop sessions of lobbies that are long gone (older than 24h)
const pruneOldSessions = () => {
  const maxAgeMs = 24 * 60 * 60 * 1000;
  for (const key of Object.keys(localStorage)) {
    if (!key.startsWith("willy:")) continue;
    try {
      const entry = JSON.parse(localStorage.getItem(key));
      if (!entry.saved_at || Date.now() - entry.saved_at > maxAgeMs) {
        localStorage.removeItem(key);
      }
    } catch {
      localStorage.removeItem(key);
    }
  }
};

// Game view (/g/CODE): restore/save/clear this lobby's session
Hooks.PlayerSession = {
  mounted() {
    const code = this.el.dataset.code;
    const saved = readSession(code);

    if (saved && saved.player_id && saved.nickname && tabJoined(code)) {
      this.pushEvent("restore_session", {
        player_id: saved.player_id,
        nickname: saved.nickname,
      });
    }

    this.handleEvent("save_session", (data) => {
      writeSession(code, data);
      markTabJoined(code);
    });
    this.handleEvent("clear_session", () => {
      localStorage.removeItem(sessionKey(code));
      sessionStorage.removeItem(tabJoinedKey(code));
    });
  },
};

// Landing page: store the freshly created host session, then tell the
// LiveView so it can navigate to the game (guarantees the session exists
// before /g/CODE mounts)
Hooks.LobbySession = {
  mounted() {
    pruneOldSessions();

    this.handleEvent("store_session", (data) => {
      writeSession(data.code, data);
      // The creator stays in this tab, so it may auto-rejoin as host
      markTabJoined(data.code);
      this.pushEvent("session_stored", { code: data.code });
    });
  },
};

Hooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const value = this.el.dataset.value;
      const done = () => {
        const original = this.el.innerText;
        this.el.innerText = "✅ Copied!";
        setTimeout(() => (this.el.innerText = original), 1500);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(value).then(done);
      } else {
        // Clipboard API needs a secure context; fall back to a prompt
        window.prompt("Copy this link:", value);
      }
    });
  },
};

Hooks.ConfirmClose = {
  mounted() {
    this.el.addEventListener("submit", (e) => {
      if (
        !confirm(
          "Are you sure you want to close the lobby? All players will be disconnected and the lobby will be deleted.",
        )
      ) {
        e.preventDefault();
      }
    });
  },
};

// Clear inputs when the LiveView pushes a "reset" event (e.g. after adding a guess word)
window.addEventListener("phx:reset", (e) => {
  const el = document.getElementById(e.detail.id);
  if (el) el.value = "";
});

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;
