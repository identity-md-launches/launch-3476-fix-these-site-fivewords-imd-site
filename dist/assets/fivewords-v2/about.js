export function createAbout(React, useDeployment, launchUrl, uniswapLink) {
  const h = React.createElement;
  const link = (href, text) => h("a", { href, target: "_blank", rel: "noreferrer" }, text);

  return function About() {
    const { manifest, address, explorer } = useDeployment();
    const imd = manifest.network.pairToken?.address;
    return h("div", { className: "page prose" },
      h("h1", null, "about"),
      h("p", null, "a mini experiment in multiplayer ai."),
      h("p", null,
        "five strangers write one image prompt, one word each. when the fifth word lands, the contract orders the image from the ",
        link("https://imd.fun", "imd swarm"),
        " in the same transaction. the next image opens five hours later. after five images it ends: 25 nfts, one per word.",
      ),
      h("p", null, "this is just a tiny five word example. ", link(launchUrl, "what will you build?")),
      h("h2", null, "please know"),
      h("ul", null,
        h("li", null, "the nfts aren't worth anything."),
        h("li", null, "the contract is immutable: no owner, no admin, no upgrades. ",
          link(`${explorer}/address/${address}#code`, "read its source"), "."),
        h("li", null, "no fees are taken. the 0.1 imd a word costs pays for the image."),
        h("li", null, "no refunds. words are public and permanent."),
        h("li", null, "metadata and the word pictures are onchain. each finished image is pinned on ipfs."),
      ),
      h("h2", null, "where to get imd"),
      h("p", null, "imd is a token on ethereum. ",
        imd ? link(uniswapLink(imd), "swap eth for imd on uniswap") : "swap eth for imd on uniswap",
        ", then come back and add your word."),
      imd && h("p", { style: { overflowWrap: "anywhere" } }, link(`${explorer}/token/${imd}`, imd)),
      h("h2", null, "how this was built"),
      h("p", null, "built by a distributed swarm of agents (imd). see the ",
        link("https://explorer.imd.fun/jobs/96f8cefc-d381-4b39-98c6-2a8ab3913f52", "prompt and job breakdown"), "."),
    );
  };
}
