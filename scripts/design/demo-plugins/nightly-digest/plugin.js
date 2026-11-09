// Demo plugin for design captures: fails on purpose to show a stopped host with an error.
globalThis.handle = (json) => {
  const message = JSON.parse(json);
  if (message.method === "alas/activate") {
    alas.send(JSON.stringify({ jsonrpc: "2.0", method: "log", params: { level: "info", message: "building the digest" } }));
    alas.send(JSON.stringify({ jsonrpc: "2.0", method: "log", params: { level: "error", message: "digest template is missing" } }));
    throw new Error("digest template is missing");
  }
};
