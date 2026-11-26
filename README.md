# fivewords

Publish the contents of `dist/` as the static root of fivewords.imd.site. The directory includes the browser modules, wallet libraries, styles, ABI and deployment manifest. It can be served directly, including from a gateway subdirectory. The site uses hash routes.

This checkout was assembled from the frontend revision identified by the project handoff. The shared frame, print lookup and About page are editable browser modules in `dist/assets/fivewords-v2/`. The collection source, Foundry configuration, tests and libraries match the released Solidity project. [Frontend revision](https://github.com/identity-md-launches/launch-3461-workflow-frontend-stage-context/tree/3d4e05169dee83b54928b965fcc064a02fba6444) · [Contract revision](https://github.com/identity-md-launches/launch-3460-workflow-contract-stage-context/tree/29c4264743a89978beb3af53dc78fcded3ffe804)

## Deployment and operation

The browser reads its Ethereum mainnet configuration from `dist/imd-deployment.json`. FiveWords is `0x241cc9f4525d6184b29e0bbc9f8af015dcaa4ea2`, deployed at block 26,496,962. The About page uses the manifest’s IMD address and Etherscan origin. [Verified collection](https://etherscan.io/address/0x241cc9f4525d6184b29e0bbc9f8af015dcaa4ea2#code) · [IMD token](https://etherscan.io/token/0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7)

For a delivered round, the frame keeps the five words visible until an image loads. It takes the CID from the on-chain IPFS URI or HTTP gateway path and first tries `https://imd-ipfs.xyz/ipfs/<CID>/artifacts/print.png`. If the browser cannot display it, or the URI has no CID, the frame uses the collection’s original `orderedAt` timestamp to narrow the block range. It reads the collection’s `WordAdded` log for that round and slot 5. That transaction also placed the original image order.

The browser uses the transaction hash in `GET https://api.imd.fun/intake/1/<transactionHash>`, reads `entries[0].admission.result.jobId`, then calls `GET https://api.imd.fun/jobs/<jobId>/result`. It displays the HTTPS URL of the file named exactly `print`. IMD serves the gateway, the two JSON responses and the image. The configured RPC providers supply historical block headers and event logs. All delivery reads work with a disconnected wallet.

If both paths fail, the sentence stays in the frame. A page reload or the next successful 12-second game refresh starts another attempt. The play page follows the round clock and shows the previous round’s frame between rounds. Once play advances beyond image 1, its delivered print appears below the active round and links to its image page. Both sizes use the same loading and retry logic as the image page and gallery.

After editing an asset, run `node scripts/site-assets.mjs` to update its SHA-256 entry. The site publisher publishes the complete static directory together and refreshes the named host’s cached entrypoint, manifest and changed JavaScript modules.

## Checks

From the repository root, run the offline checks with Foundry and Node.js 22.12 or later.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x16d45002d869d1a7a2444b19bb21d42661b957755d8816f52774009244e40b8a forge test
forge fmt --check
node --test tests/site/print.test.mjs
node scripts/site-assets.mjs --check
```

For the browser suite, serve the repository with `python3 -m http.server --bind 127.0.0.1 8000` and open `http://127.0.0.1:8000/tests/site/browser.html` in a foreground tab. The suite loads the shipped site in an iframe. A service worker scoped to the test directory replays public mainnet reads at block 26,500,572 and supplies a small PNG. The checks exercise both sources on all three routes, a gateway 403, an HTML response to an image request, an unavailable API image, recovery on reload and on the regular game refresh, and About link text and destinations. A second clock setting checks that image 1 remains visible while round 2 accepts words.

In a separate local browser check with live data, image 1 decoded at 1254 × 1254 on play, its image page and the gallery. A forced gateway 403 on each route exercised the real intake and job endpoints. Both image responses matched the job’s SHA-256, `7b7dd4c9b28c19f52aa4b709b98bbccfee94c5812b9295b1c45c30ba5fcb10bc`. [Fifth word transaction](https://etherscan.io/tx/0xaccac19952629dd05c2a90a7a35b9b22959bc7dba025ddd84fea4e60e78d00c5) · [Image job result](https://api.imd.fun/jobs/c9eff464-dbfe-46cb-834c-c94102f021b3/result)
