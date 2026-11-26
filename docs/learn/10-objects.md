# Objects

Tcl has classes and objects in `oo::class`. An object is a command, and a method is a subcommand of it. This lesson makes a `Note` class for `jot`.

<!-- checkpoint -->
```tcl
```

## A class

<!-- define -->
```tcl
oo::class create Note {
    variable text done
    constructor {t} {
        set text $t
        set done 0
    }
    method text {} { return $text }
    method done {} { set done 1; return $text }
    method show {} { return "\[[expr {$done ? "x" : " "}]\] $text" }
}
oo::class create Todo {
    superclass Note
    variable due
    constructor {t d} {
        next $t
        set due $d
    }
    method show {} { return "[next] (due $due)" }
}
```

`variable text done` makes the two names the variables of each object. [`Note create milk "buy milk"`](run: "::milk") makes an object with a name, and [`milk show`](run: "[ ] buy milk") calls a method. [`milk done`](run: "buy milk") changes it, and [`milk show`](run: "[x] buy milk") shows the change. `Note new "text"` makes an object with a name that ztcl picks, such as `::oo::Obj4`. Keep that name in a variable.

A wrong method is an error with the list of the methods: [`milk nope`](run: "error: unknown method \"nope\": must be destroy, done, show or text"). `my` calls a method of the same object from the inside: `my show`.

## A subclass

`Todo` in the box is a subclass. `superclass` names the parent class, and `next` calls the method of the same name in the parent. [`[Todo new "call Ada" friday] show`](run: "[ ] call Ada (due friday)") makes a `Todo` and shows it.

## Look inside an object

[`info object class milk`](run: "::Note") gives the class. [`info class methods Note`](run: "text done show") lists the methods. [`milk destroy`](run: "") removes the object and its command. An object stays until `destroy`: an object that the code makes and forgets uses memory until the interpreter ends.

## Reading code an agent wrote

- Each object that the code makes with `new` has a `destroy`, or it lives as long as the program on purpose.
- A method that uses a variable of the object has it in the `variable` line of the class, or in a `variable` line in the method.
- A subclass constructor calls `next` with the arguments of the parent.
- Data with no methods is a dict in most Tcl code. Look for a class that has only a constructor and getters.

## Ask an agent

> Make `jot` keep each note as an object of the class `Note`, with the methods `text`, `done`, and `show`. Destroy the object when `jot remove` removes a note.

## Try this

- Add a method `undo` that sets `done` to 0.
- Make two notes with `Note new`, and run `info class instances Note`.
- Add a `destructor { puts "bye $text" }` to the class, and destroy a note.
