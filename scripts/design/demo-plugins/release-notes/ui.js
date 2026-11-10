// Demo page: renders what the plugin posts, using Alas's theme variables. No network.
const style = document.createElement("style");
style.textContent = `
  body { margin: 0; padding: 16px 18px; color: var(--alas-text); background: var(--alas-background); font-size: 13px; }
  h1 { font-size: 15px; margin: 0 0 12px; }
  .release { border: 1px solid var(--alas-line); border-radius: 8px; padding: 10px 12px; margin-bottom: 10px; }
  .head { display: flex; align-items: baseline; gap: 8px; margin-bottom: 6px; }
  .version { font-weight: 600; }
  .date { color: var(--alas-dim); font-size: 11px; }
  .pill { font-size: 10px; border-radius: 999px; padding: 1px 7px; border: 1px solid currentColor; }
  ul { margin: 0; padding-left: 18px; }
  li { margin: 2px 0; }
  .narrow .release { padding: 8px 10px; }
`;
document.head.appendChild(style);

const tones = { success: "--alas-tone-success", info: "--alas-tone-info", warning: "--alas-tone-warning" };

function render(releases) {
  document.body.textContent = "";
  document.body.classList.toggle("narrow", window.innerWidth < 400);
  const title = document.createElement("h1");
  title.textContent = "Release notes";
  document.body.appendChild(title);
  releases.forEach((release, index) => {
    const card = document.createElement("div");
    card.className = "release";
    const head = document.createElement("div");
    head.className = "head";
    const version = Object.assign(document.createElement("span"), { className: "version", textContent: release.version });
    const date = Object.assign(document.createElement("span"), { className: "date", textContent: release.date });
    head.append(version, date);
    if (index === 0) {
      const pill = Object.assign(document.createElement("span"), { className: "pill", textContent: "latest" });
      pill.style.color = `var(${tones[release.tone]})`;
      head.appendChild(pill);
    }
    const list = document.createElement("ul");
    release.items.forEach((text) => list.appendChild(Object.assign(document.createElement("li"), { textContent: text })));
    card.append(head, list);
    document.body.appendChild(card);
  });
}

alas.onMessage((value) => render(value.releases));
alas.post({ ready: true });
