# The settings of tools/refdoc.tcl for ztcl. Each other .tcl file of this
# folder is one entry of the command reference. The format is in
# docs/dev/reference-format.md.

setting product ztcl
setting site https://beetlebug.org/ztcl/
setting repo https://github.com/beetlebugorg/ztcl
# The folder of the pages of the entries, from the root of the site.
setting prefix reference/
# The areas of the index, in order (tools/reference.py AREAS).
setting areas {strings lists dicts math variables control procs errors channels events interps objects threads system ztcl}
# The Tcl release of the shell of the pages: the command of each example
# of this release is a Run link to the shell of the page.
setting shell 9.1

# The examples run once for each release, with these flags of the runner.
# An example, a subcommand, or an entry with `tcl` runs only in that
# release.
release 9.1 {--tcl 9.1}
release 8.6 {--tcl 8.6}
