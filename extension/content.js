// Reads now-playing state from the YouTube Music / YouTube page and sends it
// to the background script (falling back to a direct request to the bridge).
(() => {
  if (window.top !== window || window.__kasetDiscordPresence) return;
  window.__kasetDiscordPresence = true;

  const api = globalThis.browser ?? globalThis.chrome;
  const config = globalThis.KASET_DISCORD_PRESENCE;
  const POLL_MS = 2000;
  const HEARTBEAT_MS = 15000;
  const isMusic = location.hostname === "music.youtube.com";

  let last = null;
  let lastSentAt = 0;

  const text = (selector) => document.querySelector(selector)?.textContent?.trim() || "";

  function bestArtwork(metadata) {
    const artwork = [...(metadata?.artwork ?? [])];
    if (!artwork.length) return null;
    const area = (a) => {
      const [w, h] = (a.sizes || "0x0").split(" ").pop().split("x").map(Number);
      return (w || 0) * (h || 0);
    };
    artwork.sort((a, b) => area(a) - area(b));
    // Google image URLs encode their size; ask for a larger square.
    return artwork.pop().src.replace(/=w\d+-h\d+/, "=w512-h512");
  }

  function videoId() {
    const fromUrl = new URLSearchParams(location.search).get("v");
    if (fromUrl) return fromUrl;
    const link = document.querySelector("ytmusic-player-bar a.ytp-title-link, a.ytp-title-link");
    return link ? new URL(link.href, location.href).searchParams.get("v") : null;
  }

  function readState() {
    const metadata = navigator.mediaSession?.metadata;
    const video = document.querySelector("video");

    let title = metadata?.title || "";
    let artist = metadata?.artist || "";
    const album = metadata?.album || "";
    if (!title) {
      title = isMusic
        ? text("ytmusic-player-bar .title")
        : text("h1.ytd-watch-metadata yt-formatted-string");
    }
    if (!artist) {
      artist = isMusic
        ? text("ytmusic-player-bar .byline").split("•")[0].trim()
        : text("ytd-watch-metadata ytd-channel-name a");
    }
    if (!title || !video) return null;

    const duration = Number.isFinite(video.duration) ? video.duration : 0;
    return {
      source: isMusic ? "music" : "youtube",
      title,
      artist,
      album,
      artwork: bestArtwork(metadata),
      videoId: videoId(),
      playing: !video.paused && !video.ended,
      position: video.currentTime || 0,
      duration,
    };
  }

  function hasChanged(state, previous) {
    if (!previous) return true;
    for (const key of ["title", "artist", "album", "artwork", "videoId", "playing"]) {
      if (state[key] !== previous[key]) return true;
    }
    if (Math.abs(state.duration - previous.duration) > 2) return true;
    if (state.playing) {
      // Detect seeks: compare against where playback should be by now.
      const expected = previous.position + (Date.now() - previous.at) / 1000;
      if (Math.abs(expected - state.position) > 3) return true;
    }
    return false;
  }

  async function send(state) {
    try {
      const response = await api.runtime.sendMessage({ type: "kaset-presence", payload: state });
      if (response?.ok) return;
    } catch (_) {
      // Background unavailable; fall through to a direct request.
    }
    try {
      await fetch(`http://127.0.0.1:${config.port}/presence`, {
        method: "POST",
        headers: { "Content-Type": "text/plain" },
        body: JSON.stringify({ ...state, token: config.token }),
      });
    } catch (_) {
      // Bridge not running; try again on the next tick.
    }
  }

  function tick() {
    const state = readState();
    if (!state) return;
    const now = Date.now();
    if (hasChanged(state, last) || now - lastSentAt > HEARTBEAT_MS) {
      lastSentAt = now;
      send(state);
    }
    last = { ...state, at: now };
  }

  let pending = null;
  const tickSoon = () => {
    clearTimeout(pending);
    pending = setTimeout(tick, 300);
  };
  for (const event of ["play", "pause", "ended", "seeked", "loadedmetadata"]) {
    document.addEventListener(event, tickSoon, true);
  }
  setInterval(tick, POLL_MS);
  tick();
})();
