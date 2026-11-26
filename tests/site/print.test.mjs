import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { apiPrint, gatewayPrint } from "../../dist/assets/fivewords-v2/print.js";

const snapshot = JSON.parse(await readFile(new URL("./round-one.json", import.meta.url)));
const abi = JSON.parse(await readFile(new URL("../../dist/abi/FiveWords.json", import.meta.url)));
const log = snapshot.fifthWord;
const image = {
  n: 1, orderedAt: Number(log.blockTimestamp),
  uri: "ipfs://bafybeigmq6qhme4m27uvg5n5fque46p3yba7bicszaynpapaytuqaylqae/result.json",
};
const jobId = "c9eff464-dbfe-46cb-834c-c94102f021b3";
const print = "https://api.imd.fun/artifacts/7b7dd4c9b28c19f52aa4b709b98bbccfee94c5812b9295b1c45c30ba5fcb10bc";
const intakeUrl = `https://api.imd.fun/intake/1/${log.transactionHash}`;
const jobUrl = `https://api.imd.fun/jobs/${jobId}/result`;
const intake = { entries: [{ admission: { result: { jobId } } }] };

function deployment(logs = [log]) {
  return {
    address: log.address, abi,
    publicClient: {
      getBlockNumber: async () => BigInt(snapshot.block),
      getBlock: async ({ blockNumber }) => ({ timestamp: BigInt(snapshot.timestamps[`0x${blockNumber.toString(16)}`]) }),
      getLogs: async ({ fromBlock, toBlock, args, address, event, strict }) => {
        assert.ok(toBlock - fromBlock < 256n);
        assert.ok(fromBlock <= BigInt(log.blockNumber) && BigInt(log.blockNumber) <= toBlock);
        assert.equal(event.name, "WordAdded");
        assert.equal(strict, true);
        assert.equal(address, log.address);
        assert.deepEqual(args, { image: 1n, slot: 5n });
        return logs;
      },
    },
  };
}

test("gateway URL uses the delivery CID and the sibling print path", () => {
  const url = "https://imd-ipfs.xyz/ipfs/bafybeigmq6qhme4m27uvg5n5fque46p3yba7bicszaynpapaytuqaylqae/artifacts/print.png";
  assert.equal(gatewayPrint(image), url);
  assert.equal(gatewayPrint({ imageURI: image.uri.replace("result.json", "artifacts/print.png") }), url);
  assert.equal(gatewayPrint({ uri: image.uri.replace("ipfs://", "https://ipfs.io/ipfs/") }), url);
  assert.equal(gatewayPrint({ uri: "https://api.imd.fun/intake-results/example" }), null);
});

test("intake lookup uses the fifth word transaction and the print file's exact URL", async (t) => {
  const calls = [];
  t.mock.method(globalThis, "fetch", async (url) => {
    calls.push(url);
    if (url === intakeUrl) return Response.json(intake);
    assert.equal(url, jobUrl);
    return Response.json({ files: [{ name: "preview", url: "https://example.org/preview" }, { name: "print", url: print }] });
  });
  assert.equal(await apiPrint(deployment(), image, new AbortController().signal), print);
  assert.deepEqual(calls, [intakeUrl, jobUrl]);
});

for (const [name, entries, files] of [
  ["intake unavailable", () => new Response("", { status: 503 })],
  ["invalid intake JSON", () => new Response("<html>")],
  ["missing first admission", () => Response.json({ entries: [{}, ...intake.entries] })],
  ["missing job result", () => Response.json(intake), () => new Response("", { status: 404 })],
  ["no print file", () => Response.json(intake), () => Response.json({ files: [{ name: "preview", url: print }] })],
  ["invalid print URL", () => Response.json(intake), () => Response.json({ files: [{ name: "print", url: "javascript:void(0)" }] })],
]) {
  test(name, async (t) => {
    const calls = [];
    t.mock.method(globalThis, "fetch", async (url) => {
      calls.push(url);
      return url === intakeUrl ? entries() : files();
    });
    await assert.rejects(apiPrint(deployment(), image, new AbortController().signal));
    assert.deepEqual(calls, files ? [intakeUrl, jobUrl] : [intakeUrl]);
  });
}

test("an absent fifth-word log never starts an intake lookup", async (t) => {
  const fetch = t.mock.method(globalThis, "fetch", () => assert.fail("unexpected request"));
  await assert.rejects(apiPrint(deployment([]), image, new AbortController().signal), /transaction unavailable/);
  assert.equal(fetch.mock.callCount(), 0);
});
