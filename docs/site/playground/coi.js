// A service worker that makes the playground cross-origin isolated.
// GitHub Pages cannot set headers, so this worker adds the headers COOP
// and COEP to each response of the site. The page registers it and
// loads one more time. Then `crossOriginIsolated` is true, and the
// threads of ztcl use one shared memory. See docs/embedding.md.
// SPDX-License-Identifier: BSD-2-Clause

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (e) => {
  const r = e.request;
  // A cache mode of "only-if-cached" works only with the mode "same-origin".
  if (r.cache === "only-if-cached" && r.mode !== "same-origin") return;
  e.respondWith(
    fetch(r).then((res) => {
      // An opaque response has no headers to change.
      if (res.status === 0) return res;
      const headers = new Headers(res.headers);
      headers.set("Cross-Origin-Opener-Policy", "same-origin");
      headers.set("Cross-Origin-Embedder-Policy", "require-corp");
      headers.set("Cross-Origin-Resource-Policy", "same-origin");
      return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
    }),
  );
});
