# Events

A Tcl program that waits for a timer, a channel, or a socket uses the event loop. `after` puts a script in the loop, and `vwait` runs the loop until a variable changes. A coroutine is a proc that stops at `yield` and goes on at its next call. This lesson gives `jot` reminders.

The shell of this page has no event loop and no `coroutine`, so the examples of this lesson run in `ztcl` on your computer. Issue [#245](https://github.com/beetlebugorg/ztcl/issues/245) adds them to the shell. The event loop is a capability: run the first example with `ztcl --allow event FILE`.

<!-- checkpoint -->
```tcl
```

## Timers

`after MS SCRIPT` runs the script after MS milliseconds, from the event loop. The script runs at the top level, so it gets its values as a list, made when `after` runs.

<!-- run: --allow event -->
```tcl
proc remind {text ms} {
    after $ms [list puts "reminder: $text"]
}
remind "call Ada" 200
remind "buy milk" 100
after 300 {set ::done 1}
vwait done
```

```text
reminder: buy milk
reminder: call Ada
```

`after` gives an id, and `after cancel ID` removes the timer. A script that `after` runs has no caller to give an error to: the error goes to `bgerror`.

## Coroutines

`coroutine NAME CMD` makes a command NAME and runs CMD until its first `yield`. The value of that `yield` is the result of `coroutine`. Each call of NAME runs to the next `yield`.

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

- In `ztcl`, change `remind` to build its script with quotes, and give it a note with a `$` in it.
- Make a coroutine that gives the numbers 1, 2, 3, and then ends.
- Run `after 100 {error boom}` and `vwait forever`, and read the error.
