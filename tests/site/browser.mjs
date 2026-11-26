const results = document.querySelector("#results");
const frame = document.querySelector("iframe");
const gateway = "https://imd-ipfs.xyz/ipfs/bafybeigmq6qhme4m27uvg5n5fque46p3yba7bicszaynpapaytuqaylqae/artifacts/print.png";
const intake = "https://api.imd.fun/intake/1/0xaccac19952629dd05c2a90a7a35b9b22959bc7dba025ddd84fea4e60e78d00c5";
const result = "https://api.imd.fun/jobs/c9eff464-dbfe-46cb-834c-c94102f021b3/result";
const print = "https://api.imd.fun/artifacts/7b7dd4c9b28c19f52aa4b709b98bbccfee94c5812b9295b1c45c30ba5fcb10bc";
const sentence = "slifer parade everlight garden candlelight";
const doc = () => frame.contentDocument;
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function check(value, message) {
  if (!value) throw new Error(message);
}
async function until(probe, label) {
  const end = Date.now() + 22000;
  while (Date.now() < end) {
    if (probe()) return;
    await pause(40);
  }
  throw new Error(`timed out waiting for ${label}. Page text: ${doc()?.body?.innerText}`);
}
let run;
async function openApp(mode, route, round = 1) {
  run = crypto.randomUUID();
  const loaded = new Promise((resolve) => frame.addEventListener("load", resolve, { once: true }));
  frame.src = `./app/?mode=${mode}&round=${round}&run=${run}${route}`;
  await loaded;
}
function imageIs(url) {
  const img = doc()?.querySelector(".frame-img");
  return img?.currentSrc === url && img.complete && img.naturalWidth > 0 && img.getBoundingClientRect().width > 0
    && img.alt === `image 1: ${sentence}`;
}
async function history() {
  const channel = new MessageChannel();
  const reads = new Promise((resolve) => { channel.port1.onmessage = ({ data }) => resolve(data); });
  navigator.serviceWorker.controller.postMessage(run, [channel.port2]);
  const paths = await reads;
  channel.port1.close();
  return paths;
}
function passed(text) { results.textContent += `PASS ${text}\n`; }

let registration;
let status = "failed";
try {
  registration = await navigator.serviceWorker.register("./worker.js");
  await navigator.serviceWorker.ready;
  await until(() => navigator.serviceWorker.controller, "offline browser fixtures");
  results.textContent = "";
  for (const route of ["", "#/image/1", "#/gallery"]) {
    for (const mode of ["gateway", "api"]) {
      await openApp(mode, route);
      await until(() => imageIs(mode === "gateway" ? gateway : print), `image 1 on /${route} via ${mode}`);
      const reads = await history();
      const expected = mode === "gateway" ? [gateway] : [gateway, intake, result, print];
      check(JSON.stringify(reads) === JSON.stringify(expected), `wrong request order: ${JSON.stringify(reads)}`);
      check(doc().querySelectorAll(".frame").length === (route === "#/gallery" ? 5 : 1), "frame count");
      if (!route) check(!doc().querySelector(".intro .lede a"), "About link leaked onto play");
      passed(`image 1 on /${route} via ${mode}`);
    }
  }

  await openApp("api", "", 2);
  await until(() => imageIs(print), "image 1 after round 2 opens");
  check(doc().querySelector("#panel-title").textContent === "image 2 of 5", "round 2 panel");
  check(!doc().querySelector("#word").disabled, "round 2 word entry");
  check(doc().querySelector(".stage .frame .sentence .blank"), "active round sentence");
  check(doc().querySelector(".frame-img").closest("a")?.hash === "#/image/1", "image 1 link");
  check(doc().querySelectorAll(".frame-img").length === 1, "duplicate print");
  passed("image 1 stays visible below the open round on the home page");

  for (const refresh of ["page reload", "game refresh"]) {
    await openApp("recover", "#/image/1");
    await until(() => doc()?.querySelector(".frame .caption")?.textContent.includes("image unavailable"), "both sources failed");
    check([...doc().querySelectorAll(".frame .w")].map((el) => el.textContent).join(" ") === sentence, "lost sentence");
    check(!doc().querySelector(".frame-img"), "broken image visible");
    if (refresh === "page reload") frame.contentWindow.location.reload();
    await until(() => imageIs(gateway), refresh);
    check(JSON.stringify(await history()) === JSON.stringify([gateway, intake, result, print, gateway]), "unexpected retries");
    passed(`sentence preserved and gateway retried on ${refresh}`);
  }

  await openApp("intake-recover", "#/gallery");
  const tile = () => doc()?.querySelector('.tile[href="#/image/1"]');
  await until(() => tile()?.querySelector(".caption")?.textContent.includes("image unavailable"), "intake failure");
  check([...tile().querySelectorAll(".w")].map((el) => el.textContent).join(" ") === sentence, "gallery lost sentence");
  frame.contentWindow.location.reload();
  await until(() => imageIs(print), "gallery recovery through the API");
  check(JSON.stringify(await history()) === JSON.stringify([gateway, intake, gateway, intake, result, print]), "intake retry order");
  passed("gallery retains the sentence and recovers through the API on reload");

  await openApp("gateway", "#/about");
  await until(() => doc()?.querySelector(".prose h2"), "About");
  const text = (node) => node?.textContent;
  const launch = doc().querySelector('a[href="https://explorer.imd.fun/launch"]');
  check(text(launch) === "what will you build?", "launch link text");
  check(launch.previousSibling?.nodeType === Node.TEXT_NODE && text(launch.previousSibling) === "this is just a tiny five word example. ", "plain first sentence");
  check(text(doc().querySelector('.prose p:first-of-type a[href="https://imd.fun"]')) === "imd swarm", "first paragraph imd swarm link");
  const token = "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7";
  const tokenLink = doc().querySelector(`.prose p a[href="https://etherscan.io/token/${token}"]`);
  check(text(tokenLink) === token && text(tokenLink.parentElement.previousElementSibling.previousElementSibling) === "where to get imd", "token link");
  const last = doc().querySelector(".prose p:last-child");
  check(text(last.previousElementSibling) === "how this was built", "last section");
  check(text(last) === "built by a distributed swarm of agents (imd). see the prompt and job breakdown.", "last paragraph");
  check(text(last.querySelector('a[href="https://explorer.imd.fun/jobs/96f8cefc-d381-4b39-98c6-2a8ab3913f52"]')) === "prompt and job breakdown", "job link");
  passed("About copy and link boundaries");
  status = "passed";
} catch (error) {
  results.textContent += `FAIL ${error.stack || error}\n`;
} finally {
  await registration?.unregister();
  results.dataset.status = status;
}
