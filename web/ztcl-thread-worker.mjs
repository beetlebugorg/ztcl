// The worker of web/ztcl-threads.mjs. One worker runs one ztcl thread:
// the main interpreter or a thread of a script.
//
// The build with one shared memory (ztcl-threads.wasm): each worker
// makes an instance of the module on the shared memory of the host. A
// thread worker calls ztcl_thread_start, which runs the whole thread.
// The waits of the thread are Atomics waits on the shared memory.
//
// The build with a memory in each worker (ztcl-async.wasm): each worker
// has its own memory. A message is a script, and a reply is the result
// as bytes. The host routes them with postMessage. The worker runs one
// message at a time, between the turns of its event loop.
// SPDX-License-Identifier: BSD-2-Clause

const node = typeof WorkerGlobalScope === "undefined";
const port = node ? (await import("node:worker_threads")).parentPort : self;
const post = (m) => port.postMessage(m);
const listen = (f) => (node ? port.on("message", f) : (port.onmessage = ({ data }) => f(data)));

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const NO_LIMIT = 0xffffffffffffffffn;
const now = () => performance.timeOrigin + performance.now();

let x = null; // the exports of the instance
let h = 0; // the interpreter of a main worker or of an async thread
let shared = false;

function bytesIn(bytes) {
  const p = x.ztcl_alloc(bytes.length || 1);
  if (!p) throw new Error("ztcl_alloc: out of memory");
  new Uint8Array(x.memory.buffer, p, bytes.length).set(bytes);
  return p;
}

function bytesOut(ptr, len) {
  // A copy: TextDecoder does not read a SharedArrayBuffer. An empty
  // slice can have an address outside the memory.
  if (len === 0) return new Uint8Array(0);
  return new Uint8Array(x.memory.buffer, ptr, len).slice();
}

function output() {
  if (x.ztcl_output_take) x.ztcl_output_take(h);
  const text = decoder.decode(bytesOut(x.ztcl_output_ptr(h), x.ztcl_output_len(h)));
  x.ztcl_output_clear(h);
  return text;
}

function evalScript(script, computeLimit) {
  x.ztcl_set_compute_limit(h, computeLimit == null ? NO_LIMIT : BigInt(computeLimit));
  const bytes = encoder.encode(script);
  const p = bytesIn(bytes);
  const rc = x.ztcl_eval(h, p, bytes.length);
  x.ztcl_free(p, bytes.length || 1);
  const result = decoder.decode(bytesOut(x.ztcl_result_ptr(h), x.ztcl_result_len(h)));
  return { ok: rc === 0, result, output: output() };
}

// Sends the output of the threads while the main interpreter waits for
// an eval.
let poll = null;
function startPoll() {
  poll = setInterval(() => {
    const text = output();
    if (text) post({ output: text });
  }, 50);
}

function setup(init) {
  const limits = init.limits ?? {};
  const n = (v) => (v == null ? 0 : v);
  const big = (v) => (v == null ? 0n : BigInt(v));
  x.ztcl_set_thread_limits(h, n(limits.maxThreads), big(limits.computeLimit), n(limits.memLimit), big(limits.totalCompute), n(limits.totalMem), n(limits.maxQueue));
  if (init.memLimit != null) x.ztcl_set_mem_limit(h, init.memLimit);
  const rc = x.ztcl_allow(h, init.caps);
  if (rc !== 0) throw new Error(rc === 2 ? "the build does not have one of these capabilities" : "ztcl_allow: out of memory");
}

// ---- The build with one shared memory ----

async function startShared(init) {
  shared = true;
  const imports = {
    env: { memory: init.memory },
    ztcl: {
      now_ms: now,
      thread_spawn: (arg) => {
        post({ spawn: arg });
        return 0;
      },
    },
  };
  const instance = await WebAssembly.instantiate(init.module, imports);
  x = { ...instance.exports, memory: init.memory };
  if (init.role === "thread") return runThread(init.arg);
  h = x.ztcl_new();
  setup(init);
  startPoll();
}

// Runs one thread on the instance of this worker. After the return the
// host can give the worker the next thread, so a new thread needs no
// new worker and no new instance.
function runThread(arg) {
  try {
    x.ztcl_thread_start(arg);
  } finally {
    // The thread returned: its stack is free for `join`.
    const done = new Int32Array(x.memory.buffer);
    const i = x.ztcl_thread_done(arg) >> 2;
    Atomics.store(done, i, 1);
    Atomics.notify(done, i);
    post({ idle: true });
  }
}

// ---- The build with a memory in each worker ----

let self_id = 0;
let ending = false;

function asyncImports() {
  const text = (p, len) => decoder.decode(bytesOut(p, len));
  return {
    ztcl: {
      now_ms: now,
      thread_create: (id, p, len) => post({ create: { id, script: text(p, len) } }),
      thread_send: (id, p, len, token) => post({ send: { to: id, token, script: text(p, len) } }),
      thread_end: () => {
        ending = true;
      },
    },
  };
}

async function startAsync(init) {
  const instance = await WebAssembly.instantiate(init.module, asyncImports());
  x = instance.exports;
  h = x.ztcl_new();
  self_id = init.id;
  x.ztcl_web_init(h, init.id, init.role === "main" ? 1 : 0);
  setup(init);
  if (init.role === "thread") {
    const r = evalScript(init.script, init.computeLimit);
    if (r.output) post({ output: r.output });
    if (!r.ok) post({ output: `Error from thread tid0x${init.id.toString(16)}\n${r.result}\n` });
    if (ending || !x.ztcl_web_waiting(h)) end();
  }
}

function end() {
  post({ exit: true });
  ending = true;
}

// A script from another thread. A token asks for a reply.
function deliver({ from, token, script }) {
  const bytes = encoder.encode(script);
  const p = bytesIn(bytes);
  const code = x.ztcl_web_recv(h, from, token, p, bytes.length);
  x.ztcl_free(p, bytes.length || 1);
  const out = output();
  if (out) post({ output: out });
  if (token) post({ reply: { to: from, token, code, bytes: bytesOut(x.ztcl_web_msg_ptr(h), x.ztcl_web_msg_len(h)) } });
  if (ending) end();
}

function reply({ token, code, bytes }) {
  const p = bytesIn(bytes);
  x.ztcl_web_reply(h, token, code, p, bytes.length);
  x.ztcl_free(p, bytes.length || 1);
  const out = output();
  if (out) post({ output: out });
}

// ---- Messages of the host ----

let queue = Promise.resolve();
listen((data) => {
  queue = queue.then(() => handle(data)).catch((e) => post({ fatal: String(e?.message ?? e) }));
});

async function handle(data) {
  if (data.init) {
    if (data.init.memory) await startShared(data.init);
    else await startAsync(data.init);
    post({ ready: true });
    return;
  }
  if (data.run != null) return runThread(data.run);
  if (ending) return;
  if (data.deliver) return deliver(data.deliver);
  if (data.reply) return reply(data.reply);
  if (data.gone) return x.ztcl_web_gone(h, data.gone);
  if (data.eval != null) {
    try {
      const r = evalScript(data.script, data.computeLimit);
      post({ id: data.eval, ...r });
    } catch (e) {
      post({ id: data.eval, error: String(e?.message ?? e) });
    }
  }
}
