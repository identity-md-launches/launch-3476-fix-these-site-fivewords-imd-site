// The collection recorded orderedAt in the same transaction that emitted WordAdded for slot 5.
const deploymentBlock = 26496962n;
const api = "https://api.imd.fun";

export function gatewayPrint(image) {
  for (const uri of [image.imageURI, image.uri]) {
    const match = /^ipfs:\/\/([a-zA-Z0-9]+)(?:\/|$)/.exec(uri);
    if (match) return `https://imd-ipfs.xyz/ipfs/${match[1]}/artifacts/print.png`;
  }
  return null;
}

async function fifthWordTransaction({ publicClient, address, abi }, image, signal) {
  const timestamp = BigInt(image.orderedAt);
  let from = deploymentBlock;
  let to = await publicClient.getBlockNumber();

  // Public RPCs cap log ranges. Narrow the search by the original order time even
  // when a visitor opens a finished round long after delivery or a later reorder.
  while (to - from >= 256n) {
    signal.throwIfAborted();
    const middle = (from + to) / 2n;
    const block = await publicClient.getBlock({ blockNumber: middle });
    if (block.timestamp === timestamp) {
      from = to = middle;
      break;
    }
    if (block.timestamp < timestamp) from = middle + 1n;
    else to = middle - 1n;
  }
  signal.throwIfAborted();
  const event = abi.find((item) => item.type === "event" && item.name === "WordAdded");
  if (!event || from > to) throw new Error("fifth word outside the available history");
  const logs = await publicClient.getLogs({
    address, event, args: { image: BigInt(image.n), slot: 5n },
    fromBlock: from, toBlock: to, strict: true,
  });
  const tx = logs.find((log) => !log.removed)?.transactionHash;
  if (!/^0x[0-9a-f]{64}$/i.test(tx)) throw new Error("fifth word transaction unavailable");
  return tx;
}

async function getJson(url, signal) {
  const response = await fetch(url, { signal, cache: "no-store", credentials: "omit" });
  if (!response.ok) throw new Error(`IMD returned ${response.status}`);
  return response.json();
}

export async function apiPrint(deployment, image, signal) {
  const tx = await fifthWordTransaction(deployment, image, signal);
  signal.throwIfAborted();
  const intake = await getJson(`${api}/intake/1/${tx}`, signal);
  const jobId = intake?.entries?.[0]?.admission?.result?.jobId;
  if (typeof jobId !== "string" || !/^[\w-]+$/.test(jobId)) throw new Error("missing job ID");
  const result = await getJson(`${api}/jobs/${encodeURIComponent(jobId)}/result`, signal);
  const print = Array.isArray(result?.files) && result.files.find((file) => file?.name === "print");
  if (typeof print?.url !== "string" || new URL(print.url).protocol !== "https:") {
    throw new Error("missing print URL");
  }
  return print.url;
}
