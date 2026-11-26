// The helpers of a docs page: small ztk apps that build a command.
//
// Each element with the class "zhelper" has a box of a fixed height and
// the Tcl code of its helper in a <details>. The page works with no
// JavaScript, and the code shows. When the box comes into view, this
// module starts the shell of the page (shell.js), loads ztk.js from the
// ztk site, and runs the code of the helper in the box. The query
// parameter `?ztk=URL` loads ztk.js from another place, for a test.
//
// The helper and the page talk with lines of `puts` that start with the
// byte 0x1e. "E id script" runs a script in the interpreter of the shell,
// and the page calls `helper::reply id ok result` in the helper. "S text"
// puts the text on the line of the shell. The reader runs it with Enter.
// A helper changes the shell only when the reader clicks its button.
//
// SPDX-License-Identifier: BSD-2-Clause

import { pageShell } from "./shell.js";

// The procs that each helper can use. helper::form and helper::row make
// the rows of the form, with a label in the first column. helper::watch
// runs a script now and after each change of the variables. helper::show
// shows a command and runs it in the shell. helper::footer makes the
// bottom of the helper: the command, its result, and the button. A
// second argument of 0 leaves out the button, for a helper with no shell.
const PRELUDE = String.raw`
namespace eval helper {
    variable rows 0
    variable n 0
    variable done {}
    variable cmd ""
}
proc helper::send {kind text} {
    puts "\x1e$kind [string map {\\ \\\\ \n \\n} $text]"
}
proc helper::run {script cb} {
    variable n
    variable done
    incr n
    dict set done $n $cb
    send E "$n $script"
}
proc helper::reply {id ok result} {
    variable done
    if {![dict exists $done $id]} return
    set cb [dict get $done $id]
    dict unset done $id
    uplevel #0 [list {*}$cb $ok $result]
}
proc helper::shell {text} {
    send S $text
}
proc helper::form {} {
    ttk::frame .f -padding {8 8 8 0}
    grid columnconfigure .f 1 -weight 1
    pack .f -side top -fill x
}
proc helper::row {text w} {
    variable rows
    incr rows
    if {$text eq ""} {
        grid x $w -sticky w -pady 2
        return $w
    }
    ttk::label .f.l$rows -text $text -width 8
    grid .f.l$rows $w -sticky ew -pady 2
    return $w
}
proc helper::watch {cmd args} {
    foreach v $args { trace add variable ::$v write "$cmd ;#" }
    uplevel #0 $cmd
}
proc helper::footer {{lines 2} {button 1}} {
    ttk::frame .foot -padding {8 4 8 8}
    ttk::label .foot.cl -text Command -width 8
    ttk::entry .foot.cmd -textvariable helper::cmd -font TkFixedFont -state readonly
    ttk::label .foot.rl -text Result -width 8
    text .foot.res -height $lines -font TkFixedFont -wrap char -relief solid -borderwidth 1
    .foot.res tag configure error -foreground #c0392b
    .foot.res configure -state disabled
    ttk::button .foot.put -text "Put in the shell" -command {helper::shell $helper::cmd}
    grid .foot.cl .foot.cmd -sticky ew -pady 2
    grid .foot.rl .foot.res -sticky ew -pady 2
    if {$button} { grid x .foot.put -sticky e -pady {6 0} }
    grid configure .foot.cl .foot.rl -sticky nw
    grid columnconfigure .foot 1 -weight 1
    pack .foot -side top -fill x
}
proc helper::show {text} {
    set helper::cmd $text
    run $text helper::result
}
proc helper::result {ok result} {
    .foot.res configure -state normal
    .foot.res delete 1.0 end
    .foot.res insert end $result [expr {$ok ? "" : "error"}]
    .foot.res configure -state disabled
}
`;

let ztk = null;
function loadZtk() {
  const url = new URLSearchParams(location.search).get("ztk") || "/ztk/play/ztk.js";
  ztk ??= import(new URL(url, location.href).href);
  return ztk;
}

// A Tcl word for any text: a quoted string with the special characters
// escaped.
export function tclWord(s) {
  return '"' + s.replace(/[\\"$[\]]/g, (c) => "\\" + c).replace(/\n/g, "\\n").replace(/\r/g, "\\r") + '"';
}

const unescape = (s) => s.replace(/\\(.)/g, (_, c) => (c === "n" ? "\n" : c));

async function start(fig) {
  const box = fig.querySelector(".zhelper-app");
  const code = fig.querySelector("details code").textContent;
  // A helper with data-shell="none" has no shell: its commands do not
  // run, and its footer has no button.
  const alone = fig.dataset.shell === "none";
  const [view, { mount }] = await Promise.all([alone ? null : pageShell(), loadZtk()]);
  let app = null;
  let buf = "";
  const replies = [];
  const flush = () => {
    if (!app) return void setTimeout(flush, 0);
    while (replies.length) app.eval(replies.shift());
  };
  const handle = (msg) => {
    const body = unescape(msg.slice(2));
    if (msg[0] === "S") view?.put(body);
    if (msg[0] === "E") {
      const sp = body.indexOf(" ");
      const r = view ? view.run(body.slice(sp + 1)) : { ok: false, result: "this page has no shell" };
      replies.push(`helper::reply ${body.slice(0, sp)} ${r.ok ? 1 : 0} ${tclWord(r.result)}`);
      setTimeout(flush, 0);
    }
  };
  const log = (t) => {
    buf += t;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (line.startsWith("\x1e")) handle(line.slice(1));
      else if (line) console.log(line);
    }
  };
  box.querySelector(".zhelper-poster")?.remove();
  app = await mount(box, { script: PRELUDE + code, size: "fill", log });
  // tools/site-helper.mjs drives the app through this property.
  fig.ztkApp = app;
  fig.classList.add("zhelper-live");
}

const SMALL = "(max-width: 640px)";

// On a small screen a helper is one line with an Open button, and it
// starts only when the reader opens it. Else it starts when it comes
// into view.
function watch(fig) {
  if (matchMedia(SMALL).matches) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "btn ghost zhelper-open";
    btn.textContent = "Open the helper";
    btn.addEventListener("click", () => {
      btn.remove();
      fig.classList.add("zhelper-opened");
      // The focus goes to the box, so that it does not go to the top of
      // the page with the removed button.
      const box = fig.querySelector(".zhelper-app");
      box.tabIndex = -1;
      box.focus({ preventScroll: true });
      begin(fig);
    });
    // The button goes on the line of the title, before the caption.
    const title = fig.querySelector(".zhelper-title");
    if (title) title.after(btn);
    else fig.querySelector(".zhelper-bar").append(btn);
    return;
  }
  fig.classList.add("zhelper-opened");
  const seen = new IntersectionObserver((entries) => {
    if (!entries.some((e) => e.isIntersecting)) return;
    seen.disconnect();
    begin(fig);
  });
  seen.observe(fig);
}

function begin(fig) {
  start(fig).catch((err) => {
    const box = fig.querySelector(".zhelper-app");
    box.textContent = "";
    const p = document.createElement("p");
    p.className = "zhelper-poster";
    p.textContent = `The helper did not start: ${err.message}`;
    box.append(p);
  });
}

if (typeof WebAssembly === "object") document.querySelectorAll(".zhelper").forEach(watch);
