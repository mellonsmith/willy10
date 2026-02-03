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

// Hooks for persisting player data in localStorage
let Hooks = {};

Hooks.PlayerSession = {
  mounted() {
    // Load player data from localStorage when mounting
    const savedPlayerId = localStorage.getItem("willy_player_id");
    const savedRole = localStorage.getItem("willy_role");
    const savedNickname = localStorage.getItem("willy_nickname");

    if (savedPlayerId && savedRole && savedNickname) {
      // Push saved data to the LiveView
      this.pushEvent("restore_session", {
        player_id: savedPlayerId,
        role: savedRole,
        nickname: savedNickname,
      });
    }

    // Listen for save_session events from LiveView
    this.handleEvent("save_session", (data) => {
      localStorage.setItem("willy_player_id", data.player_id);
      localStorage.setItem("willy_role", data.role);
      localStorage.setItem("willy_nickname", data.nickname);
    });

    // Listen for clear_session events from LiveView
    this.handleEvent("clear_session", () => {
      localStorage.removeItem("willy_player_id");
      localStorage.removeItem("willy_role");
      localStorage.removeItem("willy_nickname");
    });
  },
};

Hooks.ConfirmClose = {
  mounted() {
    this.el.addEventListener("submit", (e) => {
      if (
        !confirm(
          "Are you sure you want to close the game? All players will be disconnected and the game will end.",
        )
      ) {
        e.preventDefault();
      }
    });
  },
};

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
