# The entry format of the command reference

Each command of the reference moves from a block of `docs/reference/AREA.txt` ([the text table](reference.md)) to its own file, `docs/reference/SLUG.tcl`. SLUG is the command name with each `::` and each other character that a URL does not keep as `-`: `string.tcl`, `tcl-prefix.tcl`. One file has the command, each subcommand, each option, and each argument, with a summary, a description, and run-checked examples of each. ztk uses the same format for its widgets, with the same copy of `tools/refdoc.tcl`.

An entry is a Tcl script of declarations. The tools are Tcl scripts too, and the ztcl runner of `zig-out/bin` runs them, so the checks of an entry need no Python.

```tcl
command string {
    area strings
    since 1.0.0-beta.1
    synopsis {string SUBCOMMAND ?ARG ...?}
    summary {The commands for text: length, search, compare, change, and test.}
    description {
        The commands for text. ...
    }
    subcommand map {
        synopsis {string map ?-nocase? MAPPING STRING}
        summary {Replaces each key of a list of keys and values with its value.}
        description {
            ...
        }
        returns {The new string.}
        argument MAPPING {
            type list
            summary {A list with an even count of elements: each key followed by its value.}
        }
        option -nocase {
            type flag
            summary {Matches the keys with no regard to the case of ASCII letters.}
            description {...}
            example {string map -nocase {ab X} "AB aB"} {X X}
            error {string map -nocase {a} abc} {char map list unbalanced} NONE
        }
        example {string map {a 1 b 2} abcab} 12c12
        error {string map a} {wrong # args: should be "string map ?-nocase? charMap string"} {TCL WRONGARGS}
        see {regsub {string replace}}
    }
}
```

## The sandbox

`tools/refdoc.tcl` runs each file in a safe child interpreter (`interp create -safe`) and then removes each namespace and each command of that interpreter. Only the words of the vocabulary below are left, as aliases to procs of `refdoc.tcl`. A file that calls `exec`, `open`, `source`, `set`, or any other command stops with `invalid command name`, and so does a command substitution such as `summary [exec ...]`. A file can have no variable, no loop, and no procedure. `refdoc.tcl selftest` checks this, and CI runs it.

An example is plain Tcl in braces with no escapes: the code of `example {string map {a 1} abc} 1bc` is the text `string map {a 1} abc`. The checks run the code in a runner, never in the sandbox. A code with an unbalanced brace inside quotes, such as `string is list "a {b"`, goes in quotes with the brace escaped: `"string is list \"a \{b\""`.

## Commands

| Command | What it does |
|---|---|
| `zig-out/bin/ztcl --allow interp,file,channels,exec --tclsh tools/refdoc.tcl lint` | Checks the shape of each entry and the coverage rules below. |
| `... refdoc.tcl check zig-out/bin/ztcl ?NAME ...?` | Runs the examples and the errors of each entry, or of the named entries, in each Tcl release. |
| `... refdoc.tcl selftest` | Checks that a file that calls `exec`, `open`, `source`, `set`, `puts`, a command of a namespace, or `file` stops. |
| `... refdoc.tcl convert zig-out/bin/ztcl NAME -remove` | Converts the text entry NAME to `docs/reference/SLUG.tcl` and removes it from its text file. |
| `... refdoc.tcl pages FILE` | Writes the pages of the entries as JSON for `tools/build-docs.py`. |
| `... refdoc.tcl legacy FILE` | Writes each entry as JSON in the shape of a text entry, for `tools/reference.py`. |
| `python3 -I tools/doc-examples.py zig-out/bin/ztcl --reference` | Runs the examples of the text entries, and `refdoc.tcl check` for each Tcl entry. |

`--tclsh` must be the last flag: the words after it are the script and its arguments. ztk runs the same script with `zig-out/bin/ztk --headless --allow interp,exec tools/refdoc.tcl ...`.

`tools/reference.py` runs `refdoc.tcl legacy` and gives each Tcl entry to the index, `api.json`, `llms-full.txt`, the table of the shell (`src/shell/reference.txt`), and `tools/ref-coverage.py` in the shape of a text entry. A Tcl entry replaces the text entry of its command.

## Settings

`docs/reference/_settings.tcl` has the settings of a repository. It is not an entry, and it runs in the same kind of sandbox with two words:

| Word | Value |
|---|---|
| `setting product NAME` | `ztcl` or `ztk`. |
| `setting site URL`, `setting repo URL` | The URL of the site and of the repository. |
| `setting prefix FOLDER` | The folder of the pages, from the root of the site: `reference/`. |
| `setting index FOLDER`, `setting index_label TEXT` | The page and the name of the first link of the breadcrumb: `reference/` and Commands by default. |
| `setting areas LIST` | The areas of the index, in order. |
| `setting flags LIST` | The flags of the runner for each check. ztk has `--headless`. |
| `setting epilog SCRIPT` | Tcl code after the examples of a check, such as `exit` for a runner with an event loop. |
| `setting shell RELEASE` | The Tcl release of the shell of the pages, such as `9.1`. The command of each example of that release is a Run link to the shell. A site with no shell has no `shell`. |
| `release NAME FLAGS` | A Tcl release of the checks, such as `release 9.1 {--tcl 9.1}`. |

## The words

A word with a block runs that block with the node of the block as the place of the words inside it. A prose text loses the indent of its block and its empty first and last lines, and an empty line in it starts a new paragraph. Each other value stays as it is written.

| Word | In | Value |
|---|---|---|
| `command NAME BLOCK` | the file | The command, such as `string` or `tcl::prefix`. A file has one. |
| `subcommand NAME BLOCK` | command | A subcommand: the word after the command. |
| `option NAME BLOCK` | command, subcommand | An option, such as `-nocase`. It is the anchor of the option on its page: `#-nocase`. |
| `argument NAME BLOCK` | command, subcommand | An argument: a placeholder of the synopsis. |
| `area NAME` | command | An area of the settings. Required. |
| `kind NAME` | command | `command` (the default) or `widget`. A widget page names its subcommands "Widget commands" and shows the database name of each option. |
| `since VERSION` | command, subcommand, option | The release of the product that ships it, such as `1.0.0-beta.1`. A command that is in no release yet has the next release. Required for a command, and a subcommand or an option with no `since` has the one of its command. |
| `synopsis TEXT` | command, subcommand | One form of the call, once for each form. A word in capitals is a placeholder. The table of the shell gives a form with an option of its own, such as `string length -grapheme STRING`, the summary of that option. Required. |
| `summary TEXT` | each | One sentence. It is the meta description of the page. Required. |
| `description TEXT` | each | The full text: the rules, the edges, empty input, and how the options work together. Required, except for an argument. |
| `returns TEXT` | command, subcommand | The result. Required for a subcommand and for a command with no subcommand. |
| `type TEXT` | option, argument | The type of the value, such as `integer`, `index`, `variable name`, or `flag`. Required. |
| `value TEXT` | option | The placeholder of the value of the option, such as `N`. An option with no `value` is a flag. |
| `default TEXT` | option, argument | The value with no option or no argument. |
| `optional`, `repeats` | argument | The argument can be missing, or can come more than once. |
| `values LIST` | option, argument | The allowed values. |
| `choice NAME SUMMARY ?-tcl RELEASE?` | option, argument | One allowed value with its meaning, once for each value. |
| `dbname TEXT`, `dbclass TEXT` | option | The option database name and class of a widget option. |
| `tcl RELEASE` | command, subcommand, option | The one Tcl release that has it, such as `9.1`. Its examples run only in that release. |
| `capability NAME` | command, subcommand | The capability that it needs. |
| `flags LIST` | command, subcommand | The flags of the runner for the checks, such as `{--allow clock}`. |
| `cost TEXT` | command, subcommand | The compute cost when it is not one compute unit for the call. |
| `names LIST` | command | Other command names that the page covers. |
| `page TARGET` | command | The guide page of a module, as a link target. |
| `see LIST` | command, subcommand, option | Related commands and subcommands, such as `{regsub {string replace}}`. |
| `release TEXT` | command, subcommand | How Tcl 8.6 and Tcl 9.1 differ for it in ztcl, once for each difference. |
| `difference TEXT` | command, subcommand | How ztcl differs from Tcl, once for each difference. |
| `noerrors TEXT` | command, subcommand, option | Why it has no error, for one that accepts each call, such as `string cat`. It stands in for `error`. |
| `example CODE RESULT ?-output TEXT? ?-tcl RELEASE? ?-note TEXT?` | command, subcommand, option | An example: the code, the result of its last command, what it prints, the one release where it runs, and a note. |
| `error CODE MESSAGE ERRORCODE ?-tcl RELEASE? ?-note TEXT?` | command, subcommand, option | An error: the code, the message, and the `-errorcode` of `catch`. |

A word in a block where it has no place, a second `summary`, or a wrong count of words stops the load with an error that names the file.

## Text

A summary, a description, and the other text use a small part of Markdown: `code`, `*emphasis*`, and links `[text](target)`. An empty line starts a new paragraph, and lines that start with `- ` are a list. A link target is `cmd:NAME` for a reference page (`cmd:string map`, `cmd:lsort#-unique`), a folder of the site (`limits/#the-compute-limit`), or a URL.

Write the text from the behavior of ztcl and from the examples that you ran, with the rules of WRITING.md. No text comes from the manual pages of Tcl.

## The checks of the examples

`refdoc.tcl check` runs the examples of the command in one process, and the examples of each subcommand with the examples of its options in another, in the order of the file. The errors of a group run after its examples. Each group runs once for each `release`. An example with no `-tcl` must give the same result in each release. An entry, a subcommand, or an example with `tcl` runs only in that release, so an entry shows a difference between the releases with one example for each release.

For each example the check compares the result and the text that the code printed. For each error it compares the message and the `-errorcode` of `catch`. A runner with capabilities gets the `flags` of the entry.

## The coverage rules

`refdoc.tcl lint` reports each of these:

- a missing required word;
- a summary that is not one sentence;
- a command, a subcommand, or an option with no example, or with no error and no `noerrors`;
- a command with no subcommand, or a subcommand, with no `returns`;
- a release that is not in the settings;
- the text `TODO`, which `convert` writes for the facts that the text table does not have: `since` and the type of each option.

## The pages

`tools/build-docs.py` runs `refdoc.tcl pages`, which renders each entry as static HTML that needs no JavaScript to read:

- a page for the command at `reference/NAME/`, and a page for each subcommand at `reference/NAME/SUB/`, such as `reference/string/map/`;
- an `h1` with the name, the summary as the lead and as the meta description, the synopsis as text, the description, and tables of the subcommands, the arguments, and the options;
- a section for each option, with its anchor (`reference/string/compare/#-nocase`), its description, its examples, and its errors;
- the examples and the errors as sessions of the shell, with the `-errorcode` of each error. With `shell` in the settings, a click on a command runs it in the course shell of the page, which starts closed behind the button Try it;
- the facts (capability, Tcl release, since, compute cost), the differences between the releases and from Tcl, and the related commands;
- a breadcrumb, and JSON-LD with a `TechArticle` about the `SoftwareSourceCode` of the product and a `BreadcrumbList`.

A link of a page is `href="refdoc:TARGET"` in the JSON, and `build-docs.py` resolves it with the pages of the site and checks its anchor. The build adds the frame of the site, a canonical link, and `docs/site/reference.css`, writes `sitemap.xml` with each page, and checks each page of the output: a title, a meta description, one `h1`, a canonical link to its own URL, and a line in the sitemap.

## The shared files

ztcl and ztk have the same `tools/refdoc.tcl` and `docs/site/reference.css`. ztk keeps a copy of each, and `tools/shared.sha256` in ztk has their SHA-256 and the ztcl commit that they come from. A check of ztk compares its copies with the hashes, and CI also compares them with the files of ztcl at that commit.

## Convert an entry

`refdoc.tcl convert` writes each fact of a text entry to a Tcl entry, and checks that each text of the old entry is in the new file:

- `syn` goes to `synopsis`, and `does` to `description`, with its first sentence as `summary`.
- The `sub` lines of one subcommand go to one `subcommand`, with each synopsis in `synopsis`. The text of the first line is the summary and the description, and the text of each other line is a paragraph of the description. "Tcl 9.1 only." at the end of a text goes to `tcl`.
- `opt`, `ex`, and `err` go to `option`, `example`, and `error`. The runner runs each error to get its `-errorcode`.
- `cap`, `flags`, `cost`, `names`, `page`, `diff`, and `tcl` go to `capability`, `flags`, `cost`, `names`, `page`, `difference`, and `tcl`.

Then a person fills the rest by hand to the coverage rules, from the behavior of the runner in each release.

## The port of the rest to Tcl

The tools of the reference are in Tcl now. These parts are still in Python, in this order of the port:

1. `tools/reference.py`: the parser of the text table, the index of the reference, `api.json`, and the table of the shell. It goes into `refdoc.tcl` when the text entries are all converted, and then the text table and `reference.py` go away.
2. `tools/ref-coverage.py` and the reference part of `tools/doc-examples.py`: `refdoc.tcl` gets a `coverage` subcommand with the probe script of `ref-coverage.py`.
3. `tools/build-docs.py`: the frame of each page, the Markdown pages with markdown-it-py, the course shell, the sitemap, and the checks of the links. The Markdown renderer is the largest part. A port needs a Markdown renderer in Tcl for the subset of the docs, so it comes last.
