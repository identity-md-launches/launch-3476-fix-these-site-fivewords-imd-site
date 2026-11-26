// Offline HTTP fixtures for pages under ./app/ only. The browser still parses and paints each <img>.
const app = new URL("./app/", self.location);
const dist = new URL("../../dist/", self.location);
const snapshot = fetch(new URL("./round-one.json", self.location)).then((response) => response.json());
const gateway = "https://imd-ipfs.xyz/ipfs/bafybeigmq6qhme4m27uvg5n5fque46p3yba7bicszaynpapaytuqaylqae/artifacts/print.png";
const job = "c9eff464-dbfe-46cb-834c-c94102f021b3";
const file = "https://api.imd.fun/artifacts/7b7dd4c9b28c19f52aa4b709b98bbccfee94c5812b9295b1c45c30ba5fcb10bc";
const requests = new Map();
const headers = { "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*" };
const json = (data) => Response.json(data, { headers });
const png = () => new Response(Uint8Array.from(
  atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNwcXEBAAGcAM05XQ/4AAAAAElFTkSuQmCC"),
  (c) => c.charCodeAt(0)), { headers: { ...headers, "Content-Type": "image/png" } });

self.addEventListener("install", (event) => event.waitUntil(self.skipWaiting()));
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
self.addEventListener("message", (event) => event.ports[0].postMessage(requests.get(event.data) ?? []));

function rpc({ method, params, id }, data) {
  let result;
  switch (method) {
    case "eth_chainId": result = "0x1"; break;
    case "eth_getCode": result = "0x60"; break;
    case "eth_blockNumber": result = data.block; break;
    case "eth_getBlockByNumber":
      result = { number: params[0], timestamp: data.timestamps[params[0]], transactions: [] };
      break;
    case "eth_call":
      result = data.calls[params[0].to.toLowerCase()]?.[params[0].data];
      break;
    case "eth_getLogs": {
      const filter = params[0];
      const log = data.fifthWord;
      const matches = filter.address.toLowerCase() === log.address
        && filter.topics.length >= 3 && log.topics.slice(0, 3).every((topic, i) => topic === filter.topics[i])
        && (filter.topics[3] == null || filter.topics[3] === log.topics[3])
        && BigInt(filter.fromBlock) <= BigInt(log.blockNumber) && BigInt(log.blockNumber) <= BigInt(filter.toBlock);
      result = matches ? [log] : [];
      break;
    }
  }
  return result === undefined
    ? { jsonrpc: "2.0", id, error: { code: -32601, message: `unexpected fixture read ${method}` } }
    : { jsonrpc: "2.0", id, result };
}

async function answer(event) {
  const { request } = event;
  const url = new URL(request.url);
  const data = await snapshot;
  if (url.href.startsWith(app.href)) {
    const path = url.pathname.slice(app.pathname.length);
    const response = await fetch(new URL(path || "index.html", dist));
    if (path) return new Response(response.body, { headers: response.headers, status: response.status });
    const now = url.searchParams.get("round") === "2"
      ? Number(data.fifthWord.blockTimestamp) + 5 * 3600
      : Number(data.timestamps[data.block]);
    const clock = now * 1000;
    const html = (await response.text()).replace("<head>", `<head><script>Date.now = () => ${clock} + Math.floor(performance.now())</script>`);
    return new Response(html, { headers: { ...headers, "Content-Type": "text/html" } });
  }
  const client = await self.clients.get(event.clientId);
  if (!client?.url.startsWith(app.href)) return fetch(request);
  if (["https://ethereum-rpc.publicnode.com", "https://eth.drpc.org"].includes(url.origin)) {
    const body = await request.json();
    return json(Array.isArray(body) ? body.map((call) => rpc(call, data)) : rpc(body, data));
  }

  const params = new URL(client.url).searchParams;
  const run = params.get("run");
  const mode = params.get("mode");
  if (!requests.has(run)) requests.set(run, []);
  const log = requests.get(run);
  log.push(request.url);
  if (request.url === gateway) {
    if (mode === "gateway" || (mode === "recover" && log.filter((entry) => entry === gateway).length > 1)) return png();
    if (mode !== "recover") return new Response("forbidden", { status: 403, headers });
    return new Response("<html>unavailable</html>", { headers: { ...headers, "Content-Type": "text/html" } });
  }
  if (request.url === `https://api.imd.fun/intake/1/${data.fifthWord.transactionHash}`) {
    if (mode === "intake-recover" && log.filter((entry) => entry === request.url).length === 1) {
      return new Response("unavailable", { status: 503, headers });
    }
    return json({ entries: [{ admission: { result: { jobId: job } } }] });
  }
  if (request.url === `https://api.imd.fun/jobs/${job}/result`) {
    return json({ files: [{ name: "preview", url: "https://example.org/preview" }, { name: "print", url: file }] });
  }
  if (request.url === file && (mode === "api" || mode === "intake-recover")) return png();
  return new Response("unavailable", { status: 403, headers });
}

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (url.origin === app.origin && !url.href.startsWith(app.href)) return;
  event.respondWith(answer(event));
});
