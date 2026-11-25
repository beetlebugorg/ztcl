// The worker of WorkerInterp in ztcl.mjs. It holds one interpreter and
// runs one script for each message.
// SPDX-License-Identifier: BSD-2-Clause
import { compile, Interp } from "./ztcl.mjs";

let module = null;
let interp = null;

async function current() {
  if (!interp) interp = await Interp.create(await module);
  return interp;
}

// The messages run in order, because each one waits for the one before.
let queue = Promise.resolve();
self.onmessage = ({ data }) => {
  queue = queue.then(() => handle(data));
};

async function handle(data) {
  if (data.init) {
    module = compile(data.init);
    return;
  }
  if (data.reset) {
    interp?.close();
    interp = null;
    return;
  }
  try {
    const it = await current();
    it.stepLimit = data.stepLimit;
    if (data.memLimit != null) it.memLimit = data.memLimit;
    const r = it.eval(data.script);
    self.postMessage({ id: data.id, ...r, memorySize: it.memorySize });
  } catch (e) {
    self.postMessage({ id: data.id, error: String(e && e.message ? e.message : e) });
  }
}
