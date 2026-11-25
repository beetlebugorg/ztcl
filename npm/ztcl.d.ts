// Types of ztcl.mjs: the Tcl interpreter in WebAssembly.
// SPDX-License-Identifier: BSD-2-Clause

/**
 * A source of the WebAssembly module.
 *
 * - A URL or a URL string. In Node.js, a string with no scheme is a file path.
 * - A `Response` from `fetch`.
 * - The bytes of the file.
 * - A `WebAssembly.Module` from {@link compile}.
 */
export type WasmSource = string | URL | Response | BufferSource | WebAssembly.Module;

/** The options of an interpreter. */
export interface InterpOptions {
  /**
   * The steps of each `eval`. Each command and each loop pass uses one
   * step. At the limit, the script stops with the error
   * `step limit reached`. `null` is no limit, and it is the default.
   */
  stepLimit?: number | bigint | null;
  /**
   * The memory limit in bytes. At the limit, the script stops with the
   * error `the script used too much memory`. The default is 2 GiB.
   */
  memLimit?: number | null;
  /** Gets the text of `puts` when each `eval` ends. */
  onOutput?: ((text: string) => void) | null;
}

/** The result of one `eval`. */
export interface EvalResult {
  /** True when the script ended with no error. */
  ok: boolean;
  /** The value of the script, or the error message when `ok` is false. */
  result: string;
  /** The text of `puts` from this script. */
  output: string;
}

/** The result of one `eval` in a worker. */
export interface WorkerEvalResult extends EvalResult {
  /** The size of the linear memory of the worker interpreter in bytes. */
  memorySize?: number;
}

/** The URL of the `ztcl.wasm` file next to `ztcl.mjs`. It is the default source. */
export function wasmURL(): URL;

/**
 * Compiles `ztcl.wasm`. Compile one time and give the module to
 * {@link Interp.create} to make many interpreters.
 * @param source The module. The default is {@link wasmURL}.
 */
export function compile(source?: WasmSource): Promise<WebAssembly.Module>;

/**
 * A Tcl interpreter in its own WebAssembly instance. The interpreter
 * keeps its procs and variables from one `eval` to the next. It has no
 * files, sockets, `exec`, `clock`, or event loop.
 *
 * @example
 * const tcl = await Interp.create({ stepLimit: 1_000_000, memLimit: 64 << 20 });
 * tcl.eval("expr {6 * 7}"); // { ok: true, result: "42", output: "" }
 */
export class Interp {
  /**
   * Makes an interpreter in a new WebAssembly instance.
   * @param source The module, as for {@link compile}. Leave it out for the default.
   * @param options The limits and the output function.
   */
  static create(source?: WasmSource, options?: InterpOptions): Promise<Interp>;
  /** Makes an interpreter with the default module. */
  static create(options: InterpOptions): Promise<Interp>;

  /** Makes an interpreter in an instance of `ztcl.wasm`. Use {@link Interp.create}. */
  constructor(instance: WebAssembly.Instance, options?: InterpOptions);

  /** The steps of each `eval`. `null` is no limit. A change applies to the next `eval`. */
  stepLimit: number | bigint | null;
  /** The memory limit in bytes. A change applies to the next `eval`. */
  memLimit: number;
  /** Gets the text of `puts` when each `eval` ends. */
  onOutput: ((text: string) => void) | null;
  /**
   * The size of the linear memory in bytes. The memory never shrinks,
   * so this is the peak of the instance.
   */
  readonly memorySize: number;

  /**
   * Runs a script on the calling thread. The step limit applies to
   * this call. A script blocks the page until it ends or hits a limit.
   */
  eval(script: string): EvalResult;

  /** Frees the interpreter. Drop the object after this call. */
  close(): void;
}

/**
 * Runs scripts in a Web Worker, so a long script does not block the
 * page. `stop()` ends the worker and the script in it. The next `eval()`
 * starts a new worker with a new interpreter. It works in a browser.
 *
 * @example
 * const tcl = new WorkerInterp({ memLimit: 64 << 20 });
 * const r = await tcl.eval("set n 0; while 1 {incr n}");
 * // Another handler calls tcl.stop(), and r is { ok: false, result: "stopped" }.
 */
export class WorkerInterp {
  /**
   * @param wasm The URL of `ztcl.wasm`. Leave it out for the default.
   * @param options The limits and the output function.
   */
  constructor(wasm?: string | URL, options?: InterpOptions);
  /** Uses the default module. */
  constructor(options: InterpOptions);

  /** The steps of each `eval`. `null` is no limit. */
  stepLimit: number | bigint | null;
  /** The memory limit in bytes. `null` keeps the default. */
  memLimit: number | null;
  /** Gets the text of `puts` when each `eval` ends. */
  onOutput: ((text: string) => void) | null;

  /** Runs a script in the worker. */
  eval(script: string): Promise<WorkerEvalResult>;
  /** Makes a new interpreter in the worker for the next `eval`. */
  reset(): void;
  /**
   * Ends the worker. Each pending `eval` resolves with
   * `{ ok: false, result: "stopped" }`. The procs and variables go away.
   */
  stop(): void;
}
