# SPDX-License-Identifier: BSD-2-Clause
# Makes one HTML fragment for each record: string map, subst, format, append.
proc render {n} {
    set tpl {<div class="@CLS@"><h1>@TITLE@</h1><p>@BODY@</p><span>$id / [string toupper $name]</span></div>}
    set total 0
    for {set id 0} {$id < $n} {incr id} {
        set name user$id
        set html [string map [list @CLS@ c[expr {$id%7}] @TITLE@ "Title $id" @BODY@ [string repeat "x$id " 5]] $tpl]
        set html [subst $html]
        append out [format "%05d:%s\n" $id [string range $html 0 60]]
        incr total [string length $html]
    }
    return [list $total [string length $out]]
}
puts [render 60000]
