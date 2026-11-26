// Refresh the static file inventory after an edit. All contract and chain fields come from the release.
import { createHash } from "node:crypto";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import assert from "node:assert/strict";

const root = fileURLToPath(new URL("../dist/", import.meta.url));
const manifestPath = join(root, "imd-deployment.json");
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
async function files(dir) {
  const paths = [];
  for (const entry of await readdir(join(root, dir), { withFileTypes: true })) {
    const path = dir ? `${dir}/${entry.name}` : entry.name;
    if (entry.isDirectory()) paths.push(...await files(path));
    else if (path !== "imd-deployment.json") paths.push(path);
  }
  return paths;
}
const assets = [];
for (const path of (await files("")).sort()) {
  const bytes = await readFile(join(root, path));
  assets.push({ path, sha256: createHash("sha256").update(bytes).digest("hex") });
}
if (process.argv.includes("--check")) {
  assert.deepEqual(assets, manifest.assets);
} else {
  await writeFile(manifestPath, JSON.stringify({ ...manifest, assets }, null, 2) + "\n");
}
