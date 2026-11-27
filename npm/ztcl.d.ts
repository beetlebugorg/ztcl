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
   * The compute units of each `eval`. Each command and each loop pass uses one
   * compute unit. At the limit, the script stops with the error
   * `compute limit reached`. `null` is no limit, and it is the default.
   */
  computeLimit?: number | bigint | null;
  /**
   * The memory limit in bytes. At the limit, the script stops with the
   * error `the script used too much memory`. The default is 2 GiB.
   */
  memLimit?: number | null;
  /** Gets the text of `puts` when each `eval` ends. */
  onOutput?: ((text: string) => void) | null;
  /**
   * Capabilities to turn on. `ztcl.wasm` has only `"file"`: `source`,
   * `open` for reading, `read`, `gets`, `eof`, and `close` on the files
   * of a bundle, under `//zipfs:/app/`. `ztcl-host.wasm` also has
   * `"event"`: `after`, `after idle`, and `update`, with the events run
   * from `setTimeout`. The default is none.
   */
  allow?: ("file" | "event")[];
  /**
   * The clock of the host in milliseconds, for `"event"`. The default is
   * `Date.now`.
   */
  now?: (() => number) | null;
  /** Gets the result of each run of the events from the timer. */
  onEvents?: ((r: EvalResult) => void) | null;
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
 * const tcl = await Interp.create({ computeLimit: 1_000_000, memLimit: 64 << 20 });
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

  /** The compute units of each `eval`. `null` is no limit. A change applies to the next `eval`. */
  computeLimit: number | bigint | null;
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
   * Runs a script on the calling thread. The compute limit applies to
   * this call. A script blocks the page until it ends or hits a limit.
   */
  eval(script: string): EvalResult;

  /**
   * The size in bytes of the scripts and files of a bundle from
   * `ztcl build --wasm`. Zero for a module with no bundle.
   */
  readonly bundleSize: number;

  /**
   * Runs the scripts of a bundle in order, as `ztcl a.tcl b.tcl` does.
   * The compute limit applies to all the scripts of the call together. On
   * an error, the next scripts do not run, and `result` is
   * `"name:line: message"`. Throws for a module with no bundle.
   */
  run(): EvalResult;

  /**
   * Runs the events that are due at `now` (milliseconds on the clock of
   * the option `now`), after `allow: ["event"]`.
   */
  runEvents(now?: number): EvalResult;

  /** Gets the result of each run of the events from the timer. */
  onEvents: ((r: EvalResult) => void) | null;

  /** Frees the interpreter. Drop the object after this call. */
  close(): void;
}

/**
 * Runs the scripts of a bundle in a new interpreter, then frees it.
 *
 * @example
 * const r = await run(new URL("./app.wasm", import.meta.url), { computeLimit: 1_000_000 });
 * console.log(r.output);
 * @param source The bundle, as for {@link compile}.
 * @param options The limits, the output function, and the capabilities.
 */
export function run(source: WasmSource, options?: InterpOptions): Promise<EvalResult>;

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

  /** The compute units of each `eval`. `null` is no limit. */
  computeLimit: number | bigint | null;
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
