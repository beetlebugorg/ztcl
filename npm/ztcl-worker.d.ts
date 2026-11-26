// Types of ztcl-worker.mjs: the script that runs in a Web Worker.
// SPDX-License-Identifier: BSD-2-Clause
//
// The module has no exports. Load it as a module worker. WorkerInterp
// in the main entry does this for you. Use this entry only to make the
// worker yourself, for example with `new Worker(url, { type: "module" })`.
// The worker runs the messages in order.

/** The first message: the URL of `ztcl.wasm`. */
export interface InitMessage {
  init: string;
}

/** Runs a script. The limits apply to this script. */
export interface EvalMessage {
  id: number;
  script: string;
  computeLimit?: number | bigint | null;
  memLimit?: number | null;
}

/** Makes a new interpreter for the next script. */
export interface ResetMessage {
  reset: true;
}

/** A message to the worker. */
export type WorkerRequest = InitMessage | EvalMessage | ResetMessage;

/** The answer to an {@link EvalMessage}, with the same `id`. */
export type WorkerResponse =
  | { id: number; ok: boolean; result: string; output: string; memorySize: number }
  | { id: number; error: string };
