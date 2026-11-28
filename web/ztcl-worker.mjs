// The worker of WorkerInterp in ztcl.mjs. It holds one interpreter and
// runs one script for each message.
// SPDX-License-Identifier: BSD-2-Clause
import { compile, Interp } from "./ztcl.mjs";

let module = null;
// The capabilities and the files of the interpreter (WorkerInterp).
let setup = {};
let interp = null;

async function current() {
  if (!interp) interp = await Interp.create(await module, { allow: setup.allow ?? [], files: setup.files ?? null });
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
    setup = data.setup ?? {};
    return;
  }
  if (data.reset) {
    interp?.close();
    interp = null;
    return;
  }
  try {
    const it = await current();
    it.computeLimit = data.computeLimit;
    if (data.memLimit != null) it.memLimit = data.memLimit;
    const r = it.eval(data.script);
    // With `collect`, the files that the scripts wrote go back too.
    let files;
    if (data.collect) {
      files = {};
      for (const n of it.fileNames()) files[n] = it.readFile(n);
    }
    self.postMessage({ id: data.id, ...r, memorySize: it.memorySize, files }, files ? Object.values(files).map((b) => b.buffer) : []);
  } catch (e) {
    self.postMessage({ id: data.id, error: String(e && e.message ? e.message : e) });
  }
}
