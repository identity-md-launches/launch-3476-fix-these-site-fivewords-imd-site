import { apiPrint, gatewayPrint } from "./print.js";

export function createFrame(React, useDeployment, statusLine, shortStatus, imageCount, slots) {
  const { createElement: h, useEffect, useState } = React;

  function PictureFrame({ image, size, refresh }) {
    const deployment = useDeployment();
    const firstSource = () => {
      if (image.status !== "delivered") return { step: "words" };
      const url = gatewayPrint(image);
      return url ? { step: "gateway", url } : { step: "lookup" };
    };
    const [source, setSource] = useState(firstSource);

    useEffect(() => {
      setSource((current) => current.step === "failed" ? firstSource() : current);
    }, [refresh]);

    useEffect(() => {
      if (source.step !== "lookup") return;
      const controller = new AbortController();
      apiPrint(deployment, image, controller.signal).then(
        (url) => {
          if (!controller.signal.aborted) setSource({ step: "api", url });
        },
        () => {
          if (!controller.signal.aborted) setSource({ step: "failed" });
        },
      );
      return () => controller.abort();
    }, [source.step, deployment, image.n, image.orderedAt]);

    const phrase = image.words.slice(0, image.wordCount).join(" ");
    const sentence = !source.loaded && h("p", {
      className: "sentence",
      "aria-label": image.wordCount ? `the words so far: ${phrase}` : "no words yet",
    }, Array.from({ length: slots }, (_, i) => i < image.wordCount
      ? h("span", { key: i, className: "w" }, image.words[i])
      : h("span", { key: i, className: "w blank", "aria-hidden": true }, "____")
    ));
    const picture = source.url && h("img", {
      key: source.url, className: "frame-img", src: source.url, alt: `image ${image.n}: ${phrase}`,
      style: source.loaded ? undefined : { display: "none" },
      onLoad: () => setSource({ ...source, loaded: true }),
      onError: () => setSource({ step: source.step === "gateway" ? "lookup" : "failed" }),
    });
    const caption = size === "small" ? shortStatus(image) : statusLine(image);
    return h("figure", { className: `frame frame-${size}` },
      sentence, picture, h("figcaption", { className: "caption" },
        h("span", null, `${image.n}/${imageCount}`),
        h("span", null, source.step === "failed" ? "image unavailable" : caption),
      ),
    );
  }

  return function Frame({ image, size = "large", refresh }) {
    // Give a new delivery its own image element and cancel work for the previous route.
    const key = [image.n, image.status, image.requestId, image.uri, image.imageURI].join("|");
    return h(PictureFrame, { key, image, size, refresh });
  };
}
