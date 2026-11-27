# The table of the command reference

The files `docs/reference/AREA.txt` are one table with an entry for each command or ensemble. `tools/reference.py` reads them. `tools/build-docs.py` makes a page of each entry at `reference/NAME/`, the index at `reference/`, `reference/api.json`, and the end of `llms-full.txt`. `tools/doc-examples.py --reference` runs the examples, and `tools/ref-coverage.py` checks that each registered command and each subcommand of an ensemble has an entry. `python3 -I tools/reference.py shell-table > src/shell/reference.txt` writes the table of the shell: the synopsis, the subcommands, and the options, with the first sentence of each description. Run it after a change of a `syn`, `sub`, or `opt` line. CI checks that the file is current.

An entry starts with `== NAME`. Each other line is `key: value`. A line that starts with `#` is a comment.

| Key | Count | Value |
|---|---|---|
| `syn` | one or more | A synopsis. |
| `does` | one | What the command does and gives, in our own words. |
| `sub` | any | `SYNOPSIS \| TEXT`: one subcommand. |
| `opt` | any | `FLAG \| TEXT`: one option. |
| `ex` | any | `COMMAND => RESULT`, or `COMMAND` for no check. The examples of an entry run in one interpreter, in order. |
| `err` | any | `COMMAND \| MESSAGE`: an error and its exact message. |
| `cap` | at most one | The capability that the command needs. The page shows its examples as code. |
| `flags` | at most one | The flags of the runner for the checks of an entry with `cap`, such as `--allow clock`. |
| `cost` | at most one | The compute cost when it is not one unit for the call. |
| `names` | any | Other command names that the page covers, such as `tsv::get`. |
| `page` | at most one | The full page of a `ztcl::` module, from `docs/`. |
| `diff` | any | A difference from Tcl 8.6. |

Write each `does`, `sub`, and `opt` from the behavior of ztcl and its tests, with the rules of WRITING.md. The model of the reference is the documentation of Tcl ([docs/references/tcl.md](../references/tcl.md)), and no text comes from it.
