// Relays now-playing state from the content script to the local bridge,
// which owns the Discord IPC connection.
const api = globalThis.browser ?? globalThis.chrome;
const config = globalThis.KASET_DISCORD_PRESENCE;

async function postToBridge(payload) {
  const response = await fetch(`http://127.0.0.1:${config.port}/presence`, {
    method: "POST",
    // text/plain keeps this a "simple" request (no CORS preflight).
    headers: { "Content-Type": "text/plain" },
    body: JSON.stringify({ ...payload, token: config.token }),
  });
  return response.ok;
}

api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "kaset-presence") return;
  postToBridge(message.payload)
    .then((ok) => sendResponse({ ok }))
    .catch(() => sendResponse({ ok: false }));
  return true;
});
