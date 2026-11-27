// Runs the Tcl script of a demo page of the Web APIs (bluetooth.html,
// ...): it shows the source, checks the support of the browser, and
// evaluates the script in ztcl-host.wasm with the grants of the page.
// The script starts no device and no sound before a click of the user.
//
// SPDX-License-Identifier: BSD-2-Clause
import { Interp } from "./ztcl.mjs";
import * as web from "./ztcl-web.mjs";

/// `script` is the URL of the Tcl file, `allow` the grants, `supported`
/// a test of the browser, and `missing` the text for a browser without
/// the API. Gives the Interp, or null.
export async function runDemo({ script, allow, supported, missing, ready }) {
  const text = await (await fetch(new URL(script, import.meta.url))).text();
  document.getElementById("src").textContent = text;
  const say = document.getElementById("support");
  const out = document.getElementById("out");
  if (!supported()) {
    say.textContent = missing;
    for (const b of document.querySelectorAll("#app button")) b.disabled = true;
    return null;
  }
  const tcl = await Interp.create(new URL("ztcl-host.wasm", import.meta.url), {
    allow: ["dom", "event", ...allow],
    web,
    domRoot: document.getElementById("app"),
    onEvents: (r) => {
      if (!r.ok) out.textContent += `error: ${r.result}\n`;
    },
  });
  const r = tcl.eval(text);
  say.textContent = r.ok ? ready : `error: ${r.result}`;
  return tcl;
}
