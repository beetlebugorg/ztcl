# Events

A Tcl program that waits for a timer, a channel, or a socket uses the event loop. `after` puts a script in the loop, and `vwait` runs the loop until a variable changes. A coroutine is a proc that stops at `yield` and goes on at its next call. This lesson gives `jot` reminders.

The shell of this page has the event loop on a virtual clock. A wait of the loop moves the clock to the next timer at once, so a timer of 200 ms runs with no wait. `ztcl` on your computer waits the real time. The event loop is a capability there: run a script with `ztcl --allow event FILE`.

<!-- checkpoint: --allow event -->
```tcl
```

## Timers

`after MS SCRIPT` runs the script after MS milliseconds, from the event loop. The script runs at the top level, so it gets its values as a list, made when `after` runs.

<!-- define -->
```tcl
proc remind {text ms} {
    after $ms [list puts "reminder: $text"]
}
```

[`remind "call Ada" 200`](run:) and [`remind "buy milk" 100`](run:) put two timers in the loop. No reminder prints yet. [`after 300 {set ::done 1}`](run:) adds a third timer. [`vwait done`](run: "") runs the loop until the third timer sets `done`: the reminders print in the order of their times.

`after` gives an id, and `after cancel ID` removes the timer: [`after cancel [remind "never" 50]`](run: ""). A script that `after` runs has no caller to give an error to. The error goes to `bgerror`: [`after 0 {error boom}; update`](run: "") prints the error and goes on.

## Coroutines

`coroutine NAME CMD` makes a command NAME and runs CMD until its first `yield`. The value of that `yield` is the result of `coroutine`. Each call of NAME runs to the next `yield`.

The shell of this page has no `coroutine`, so run this example in `ztcl` on your computer.

<!-- run: native -->
```tcl
coroutine tags apply {{notes} {
    yield
    foreach n $notes {
        foreach t [regexp -all -inline {#\w+} $n] { yield $t }
    }
    return ""
}} {"buy milk #shop" "fix the bike #home #shed"}
while {[set t [tags]] ne ""} { puts $t }
```

```text
#shop
#home
#shed
```

The first `yield` has no value, so that the first call of `tags` gives the first tag. A coroutine that ends with `return` is gone, and a call after that is an error.

## Reading code an agent wrote

- A script for `after` is built with `list`, so that a value with a space or a `$` stays one word.
- A program with timers runs the event loop: `vwait`, or the loop of a GUI. A script with `after` and no loop ends before the timers.
- `vwait` in a proc that a timer calls makes a nested loop. Look for one `vwait` at the top of the program.
- A coroutine that gets its values on its first call has a `yield` with no value first.

## Ask an agent

> Add `jot::remind {i minutes}` that prints the note `i` after the given minutes with `after`. Build the script with `list`, keep the timer ids in a dict, and add `jot::cancel {i}`.

## Try this

- Change `remind` to build its script with quotes, and give it a note with a `$` in it.
- Make a coroutine that gives the numbers 1, 2, 3, and then ends.
- Run `after 100 {error boom}` and `vwait forever`, and read the error.
