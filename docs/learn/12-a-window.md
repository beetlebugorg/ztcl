# A window

ztk is the Tk GUI toolkit on ztcl. A window is a tree of widgets with names such as `.f.list`, and a widget is a command. Geometry managers (`grid` and `pack`) place the widgets, and `bind` runs a script on an event. This lesson gives `jot` a window.

<!-- checkpoint -->
```tcl
```

## The jot window

The window below runs in this page with ztk on WebAssembly. Add a note, and double-click a note to mark it done. Its code is below the window. On your computer, save the code as `jot-window.tcl` and run `ztk jot-window.tcl`.

<!-- helper: The jot window | A ztk window with the notes of jot. Type a note and press Enter, or double-click a note. -->
```tcl
# height: 300
# shell: none
# toy
set notes [list [dict create text "buy milk" done 1] [dict create text "fix the bike" done 0]]
set text ""
ttk::frame .f -padding 10
pack .f -fill both -expand 1
ttk::entry .f.e -textvariable text
ttk::button .f.add -text "Add" -command add
listbox .f.list -height 7 -activestyle none
ttk::label .f.status -textvariable status
grid .f.e .f.add -sticky ew -pady {0 8}
grid .f.list - -sticky nsew
grid .f.status - -sticky w -pady {6 0}
grid columnconfigure .f 0 -weight 1
grid rowconfigure .f 1 -weight 1
bind .f.e <Return> add
bind .f.list <Double-1> toggle

proc refresh {} {
    global notes status
    .f.list delete 0 end
    set open 0
    foreach n $notes {
        set done [dict get $n done]
        .f.list insert end "[expr {$done ? "✓" : "•"}] [dict get $n text]"
        if {!$done} { incr open }
    }
    set status "$open open of [llength $notes]"
}
proc add {} {
    global notes text
    if {[string trim $text] eq ""} return
    lappend notes [dict create text $text done 0]
    set text ""
    refresh
}
proc toggle {} {
    global notes
    set i [.f.list curselection]
    if {$i eq ""} return
    set n [lindex $notes $i]
    lset notes $i [dict replace $n done [expr {![dict get $n done]}]]
    refresh
}
refresh
```

## How it works

- `ttk::entry .f.e -textvariable text` links the entry to the variable `text`. A change of one changes the other.
- `grid .f.e .f.add` puts two widgets in one row. `-` in a row extends the widget to its left by one column. `grid columnconfigure .f 0 -weight 1` gives the extra width to column 0.
- `bind .f.e <Return> add` runs `add` on the Enter key in the entry. The script of a binding runs at the top level, as the script of `after` does.
- `refresh` builds the list again from `notes`. The data is in `notes`, and the window shows it. The procs change the data, then call `refresh`.

## Reading code an agent wrote

- The data of the app is in variables or a namespace, and the widgets show it. Look for code that reads the state back from the text of a widget.
- A script of `bind` or `-command` that has a value in it is built with `list`. `-command "delete $name"` breaks for a name with a space.
- A long job runs in steps with `after`, or in a thread. A loop in a binding stops the window until it ends.
- Each widget name starts with `.`, and the name of a child starts with the name of its parent.

## Ask an agent

> Add a "Remove done" button to the jot window that removes each note that is done. Keep the notes in the variable `notes`, and call `refresh` after each change.

## Try this

- In `ztk` on your computer, add a `ttk::checkbutton` that hides the notes that are done.
- Change `-height 7` of the list, and see the window change.
- Read [the widget pages of ztk](https://beetlebug.org/ztk/widgets/) for the other widgets.
