# Tcl in a web page

`ztcl-host.wasm` gives a script the command `dom` when the page allows it. The script reads and changes the elements below one root element, and runs a script for each event that you choose. No command runs JavaScript, and the script reaches no element outside the root.

The box below is a page with an input, a button, and an empty list. The Tcl code connects them. Type a note and press Enter or Add. Then change the code, for example the text of `puts`: the page runs it again.

<!-- dom -->
```tcl
set input [dom query #item]
set list [dom query #list]
proc add {} {
    global input list
    set text [string trim [dom value $input]]
    if {$text eq ""} return
    set li [dom create li]
    dom text $li $text
    dom append $list $li
    dom value $input ""
    dom text [dom query #count] "Notes: [llength [dom queryAll li]]"
    puts "added: $text"
}
dom on [dom query #add] click add
dom on $input keydown {if {"%key" eq "Enter"} add}
```

```html
<p><input id="item" placeholder="A note" aria-label="A note"> <button id="add" type="button">Add</button></p>
<ul id="list"></ul>
<p id="count">Notes: 0</p>
```

## Turn it on

`dom` exists only in `ztcl-host.wasm`, and only after the page gives the capability. `ztcl.wasm` has no `dom`. `zig build wasm-host` writes `zig-out/lib/ztcl-host.wasm`. The npm package does not have this file yet, so serve it next to `web/ztcl.mjs`.

```js
import { Interp } from "./ztcl.mjs";
const tcl = await Interp.create(new URL("ztcl-host.wasm", import.meta.url), {
  allow: ["dom", "event"],
  domRoot: document.querySelector("#app"),
  computeLimit: 10_000_000,
  onEvents: (r) => { if (!r.ok) console.error(r.result); },
});
tcl.eval(script);
```

| Option | What it does |
|---|---|
| `allow: ["dom"]` | Adds the command `dom`. |
| `domRoot` | The root element. The default is `document.body`. |
| `allow: ["dom-html"]` | Also lets `dom html el value` set HTML. Without it, a set of HTML is an error. |
| `domComputeLimit` | The compute units of each event script. The default is 1,000,000. |
| `allow: ["event"]` | Adds `after`, `after idle`, and `update`, which run from timers of the page. |
| `onEvents(r)` | Gets the `{ ok, result, output }` of each run of the events. |

## The commands

An element is a handle: the text `dom1`, `dom2`, and so on. A command with no element uses the root.

| Command | What it does |
|---|---|
| `dom query ?el? selector` | The first match of a CSS selector below the element, or `""`. |
| `dom queryAll ?el? selector` | A list of all matches. |
| `dom text el ?value?` | Gets or sets the text. |
| `dom attr el name ?value?` | Gets or sets an attribute. An absent attribute gives `""`. |
| `dom class el add\|remove\|toggle\|has name` | Changes or reads a class. `toggle` and `has` give 0 or 1. |
| `dom style el property ?value?` | Gets or sets one property of the inline style. |
| `dom value el ?value?` | Gets or sets the value of a form element: 0 or 1 for a checkbox or a radio button. |
| `dom focus el` | Moves the focus to the element. |
| `dom create tag` | Makes a new element, outside the page. A tree of new elements is in scope before `dom append`. |
| `dom append parent child` | Puts the child at the end of the parent. |
| `dom remove el` | Takes the element out of the page. The handle ends. |
| `dom html el ?value?` | Gets the inner HTML, or sets it with the grant `dom-html`. |
| `dom on el event script` | Runs the script for each event of that name on the element. |
| `dom off el event` | Removes the script of `dom on`. |

Each command uses one compute unit, and the text that it gives counts in the memory limit.

## Events

`dom on` keeps the script, and the page puts each event in a queue. A timer of the page runs the queue with `runEvents`, so an event script runs after the current `eval` ends, at the global level. Before the run, these codes in the script change to the values of the event:

| Code | Value |
|---|---|
| `%x`, `%y` | The position of the pointer in the window (`clientX`, `clientY`). |
| `%key` | The key of a key event, such as `Enter` or `a`. |
| `%value` | The value of the target: the text of an input, or 0 or 1 for a checkbox or a radio button. |
| `%target` | The handle of the element of the event. |
| `%%` | One `%`. |

Each event script has its own compute limit, so a script that does not end stops alone with `compute limit reached`, and the page keeps working. `after ms script` and `after idle script` run from the same pump: after each `eval` and each run of the events, a timer of `setTimeout` waits for the next event. `vwait` and `after ms` with no script give an error, because a call into WebAssembly cannot wait for the page.

## Safety

- The table of handles is in `web/ztcl.mjs`. Tcl gets a name and never a pointer. Each command checks that the element is the root, below the root, or a new element of `dom create`. A handle of an element outside the root gives `invalid DOM handle "domN"`.
- `dom create` gives an error for `script`, `iframe`, `frame`, `frameset`, `object`, `embed`, `base`, `link`, `meta`, and `template`.
- `dom attr` gives an error for each attribute whose name starts with `on`, for `srcdoc` and `is`, and for a value that starts with `javascript:` or `vbscript:`.
- `dom html` sets HTML only with the grant `dom-html`. Give it only to a script that you trust as much as the code of your page.

## Coming

- `web::root`, `web::get`, `web::set`, `web::call`, and `web::release`: handles to JavaScript objects that the page gives, in pull request [#400](https://github.com/beetlebugorg/ztcl/pull/400).
- `fetch` with a list of allowed origins, as a capability of its own.

[WebAssembly](webassembly.md) has the other builds, the JS module, and the bundles of `ztcl build --wasm` and `ztcl build --component`.
