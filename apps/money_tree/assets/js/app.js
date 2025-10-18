import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

const Hooks = window.MoneyTreeHooks || {};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: {
    _csrf_token: csrfToken
  }
});

liveSocket.connect();

window.LiveSocket = liveSocket;
window.MoneyTreeHooks = Hooks;

export { Hooks, liveSocket };
