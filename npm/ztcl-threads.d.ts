// Types of ztcl-threads.mjs: ztcl with the capability `thread`.
// SPDX-License-Identifier: BSD-2-Clause

/** The capabilities that a thread interpreter can turn on. */
export type ThreadCapability = "thread" | "event" | "clock" | "package" | "interp";

/** The limits of the threads. A missing field keeps its default. */
export interface ThreadLimits {
  maxThreads?: number;
  stepLimit?: number;
  memLimit?: number;
  totalSteps?: number;
  totalMem?: number;
  maxQueue?: number;
}

export interface ThreadInterpOptions {
  /** "shared" needs Node.js or a cross-origin isolated page. "auto" picks "shared" when it can. */
  mode?: "auto" | "shared" | "async";
  /** The URL or path of ztcl-threads.wasm. */
  wasm?: string | URL;
  /** The URL or path of ztcl-async.wasm. */
  asyncWasm?: string | URL;
  /** The default is ["thread"]. "event" works only in the shared mode. */
  allow?: ThreadCapability[];
  limits?: ThreadLimits;
  /** The steps of each eval of the main interpreter. */
  stepLimit?: number | null;
  memLimit?: number | null;
  /** The text of `puts` of each thread. */
  onOutput?: ((text: string) => void) | null;
}

export interface ThreadEvalResult {
  ok: boolean;
  result: string;
  output: string;
}

/** True in Node.js and on a cross-origin isolated page. */
export function isolated(): boolean;
export function threadsURL(): URL;
export function asyncURL(): URL;

/** A main interpreter in a worker, with one worker for each thread. */
export class ThreadInterp {
  static create(options?: ThreadInterpOptions): Promise<ThreadInterp>;
  readonly mode: "shared" | "async";
  stepLimit: number | null;
  onOutput: ((text: string) => void) | null;
  /** Runs a script in the main interpreter. */
  eval(script: string): Promise<ThreadEvalResult>;
  /** Stops each worker. */
  close(): void;
}
