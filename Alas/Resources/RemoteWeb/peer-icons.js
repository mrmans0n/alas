// The icon each Mac picks for itself (`hello.icon`, `hello.peers[].icon`),
// mirroring AlasRemoteKit's `PeerIcon` raw values. Pure module: literal,
// trusted SVG strings (never interpolated with server data), so callers may
// set them via innerHTML. An unknown or missing id draws the laptop.

const PEER_ICON_IDS = [
  "laptop", "desktop", "macMini", "macStudio", "macPro", "server", "rack", "cloud",
  "chip", "terminal", "drive", "home", "office", "globe", "bolt", "flask",
];

const PEER_ICON_PATHS = {
  laptop: '<rect x="3" y="3.5" width="10" height="7" rx="1"/><path d="M1.5 12.5h13"/>',
  desktop: '<rect x="2" y="2.5" width="12" height="8.5" rx="1"/><path d="M8 11v2.5M5.5 13.5h5"/>',
  macMini: '<rect x="1.5" y="6" width="13" height="4.5" rx="1.5"/><path d="M4.5 8.25h.01"/>',
  macStudio: '<rect x="2.5" y="4" width="11" height="8.5" rx="1.5"/><path d="M5 10h1.5M11 10h.01"/>',
  macPro: '<rect x="4" y="4" width="8" height="10.5" rx="1"/><path d="M5.5 4V2h1.5M10.5 4V2H9M6.5 7h.01M9.5 7h.01M8 8.75h.01M6.5 10.5h.01M9.5 10.5h.01M8 12.25h.01"/>',
  server: '<rect x="2.5" y="2" width="11" height="3.5" rx="0.8"/><rect x="2.5" y="6.25" width="11" height="3.5" rx="0.8"/><rect x="2.5" y="10.5" width="11" height="3.5" rx="0.8"/><path d="M4.5 3.75h1M4.5 8h1M4.5 12.25h1"/>',
  rack: '<rect x="1.5" y="5.5" width="13" height="5" rx="0.8"/><path d="M3.5 8h1M6 8h1M10.5 7v2M12.5 7v2"/>',
  cloud: '<path d="M4.5 12.5a3 3 0 0 1-.4-6A4 4 0 0 1 11.8 6a3.25 3.25 0 0 1-.3 6.5z"/>',
  chip: '<rect x="4" y="4" width="8" height="8" rx="1"/><rect x="6.25" y="6.25" width="3.5" height="3.5" rx="0.5"/><path d="M6 1.5V4M10 1.5V4M6 12v2.5M10 12v2.5M1.5 6H4M1.5 10H4M12 6h2.5M12 10h2.5"/>',
  terminal: '<rect x="1.5" y="2.5" width="13" height="11" rx="1.5"/><path d="M4.5 6.5l2 1.5-2 1.5M8 10.5h3.5"/>',
  drive: '<path d="M2 9.5L4 4h8l2 5.5v3a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1zM2 9.5h12M11.5 11.5h.01M9.5 11.5h.01"/>',
  home: '<path d="M2 7.5L8 2.5l6 5M3.5 6.5v7h9v-7M6.5 13.5v-4h3v4"/>',
  office: '<path d="M3 14.5V2.5h6.5v12M9.5 6.5H13v8M1.5 14.5h13M5 5h2M5 8h2M5 11h2M11 9h.5M11 11.5h.5"/>',
  globe: '<circle cx="8" cy="8" r="6"/><path d="M2 8h12M8 2c-2 2.2-2 9.8 0 12M8 2c2 2.2 2 9.8 0 12"/>',
  bolt: '<path d="M9 1.5L3.5 9H8l-1 5.5L12.5 7H8z"/>',
  flask: '<path d="M6.5 1.5h3M7 1.5v4.5L2.75 13a1 1 0 0 0 .85 1.5h8.8a1 1 0 0 0 .85-1.5L9 6V1.5M4.5 10h7"/>',
};

const PEER_ICON_ID_SET = new Set(PEER_ICON_IDS);

function isPeerIconId(id) {
  return typeof id === "string" && PEER_ICON_ID_SET.has(id);
}

function peerIconSVG(id) {
  const body = PEER_ICON_PATHS[isPeerIconId(id) ? id : "laptop"];
  return '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + body + "</svg>";
}

globalThis.RemotePeerIcons = { PEER_ICON_IDS, isPeerIconId, peerIconSVG };
