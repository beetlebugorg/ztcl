# The msgcat package 1.6.1, as the manual page msgcat.n of Tcl 8.6
# describes it. src/clock.zig evaluates this file when it turns on the
# capability clock.
#
# A package is a namespace: each command works on the namespace of its
# caller. Msgs is a dict of namespace, locale, and source text to the
# translation. The global locale has a list of preferences (de_ch gives
# de_ch de {}) and a list of loaded locales. A package with its own
# locale has its own two lists. A change of a locale loads each new
# locale of the preferences for each package with a folder (mcfolder)
# or a load callback (loadcmd), and then calls each changecmd.
#
# The messages of the namespace ::tcl::clock also go to the store of
# src/clock.zig through ::tcl::clock::SetMsg, for the formats of clock.
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::msgcat {
    namespace export mc mcexists mcflmset mcflset mcload mclocale \
        mcloadedlocales mcmax mcmset mcpackageconfig mcpackagelocale \
        mcpreferences mcset mcunknown mcforgetpackage
    variable Msgs [dict create]
    variable Locale ""
    variable Loclist {{}}
    variable LoadedLocales {}
    # The options of each package: a dict of namespace to a dict of
    # mcfolder, loadcmd, changecmd, and unknowncmd.
    variable Config [dict create]
    # The own locale of each package: a dict of namespace to a dict of
    # locale, loclist, and loaded.
    variable PkgLocale [dict create]
    # The locale of the message file that mcload reads now.
    variable FileLocale {}
}

# The preferences of a locale: the locale and each shorter prefix at an
# underscore, then the root.
proc ::msgcat::Preferences {locale} {
    set out {}
    while {$locale ne ""} {
        lappend out $locale
        set i [string last _ $locale]
        if {$i < 0} break
        set locale [string range $locale 0 [expr {$i - 1}]]
    }
    lappend out {}
    return $out
}

# A locale of the environment, language[_country][.codeset][@modifier],
# as language[_country][_modifier].
proc ::msgcat::ConvertLocale {value} {
    if {![regexp {^([^_.@]+)(?:_([^.@]*))?(?:\.[^@]*)?(?:@(.*))?$} $value -> lang country mod]} {
        return $value
    }
    set out $lang
    if {$country ne "" || $mod ne ""} {append out _$country}
    if {$mod ne ""} {append out _$mod}
    return [string tolower $out]
}

proc ::msgcat::Caller {} {
    return [uplevel 2 {::namespace current}]
}

proc ::msgcat::mclocale {args} {
    variable Locale
    variable Loclist
    variable LoadedLocales
    variable PkgLocale
    variable Config
    if {[llength $args] > 1} {
        return -code error "wrong # args: should be \"mclocale ?newLocale?\""
    }
    if {[llength $args] == 1} {
        set new [string tolower [lindex $args 0]]
        if {[regexp {[/\\]} $new]} {
            return -code error "invalid newLocale value \"$new\":\
                could be path to unsafe code."
        }
        if {$new ne $Locale} {
            set Locale $new
            set Loclist [Preferences $new]
            set fresh {}
            foreach l $Loclist {
                if {$l ni $LoadedLocales} {lappend fresh $l}
            }
            lappend LoadedLocales {*}$fresh
            if {[llength $fresh]} {
                foreach ns [dict keys $Config] {
                    if {![dict exists $PkgLocale $ns]} {Load $ns $fresh}
                }
            }
            foreach ns [dict keys $Config] {
                if {[dict exists $PkgLocale $ns]} continue
                set cmd [GetOption $ns changecmd]
                if {$cmd ne ""} {Callback $ns $cmd {*}$Loclist}
            }
        }
    }
    return $Locale
}

proc ::msgcat::mcpreferences {} {
    variable Loclist
    return $Loclist
}

# The locale, the preferences, and the loaded locales of a package:
# its own when it has its own locale, else the global ones.
proc ::msgcat::PkgPrefs {ns} {
    variable PkgLocale
    variable Loclist
    if {[dict exists $PkgLocale $ns]} {return [dict get $PkgLocale $ns loclist]}
    return $Loclist
}

proc ::msgcat::PkgLoaded {ns} {
    variable PkgLocale
    variable LoadedLocales
    if {[dict exists $PkgLocale $ns]} {return [dict get $PkgLocale $ns loaded]}
    return $LoadedLocales
}

proc ::msgcat::GetOption {ns option} {
    variable Config
    if {[dict exists $Config $ns $option]} {return [dict get $Config $ns $option]}
    return
}

# Runs a callback of a package. An error goes to the handler of
# background errors.
proc ::msgcat::Callback {ns cmd args} {
    if {![namespace exists $ns]} return
    if {[catch {namespace eval $ns [list {*}$cmd {*}$args]} msg opts]} {
        if {[llength [info commands ::after]]} {
            ::after 0 [list ::return -options [dict remove $opts -level] $msg]
        }
    }
}

# Loads locales for a package: the loadcmd, then the message files of
# its folder. Gives the count of the files.
proc ::msgcat::Load {ns locales} {
    variable FileLocale
    set cmd [GetOption $ns loadcmd]
    if {$cmd ne ""} {Callback $ns $cmd {*}$locales}
    set dir [GetOption $ns mcfolder]
    if {$dir eq ""} {return 0}
    set n 0
    foreach l $locales {
        set name [expr {$l eq "" ? "ROOT" : $l}]
        set f [file join $dir $name.msg]
        if {![file exists $f]} continue
        set saved $FileLocale
        set FileLocale $l
        try {
            namespace eval $ns [list ::source -encoding utf-8 $f]
        } finally {
            set FileLocale $saved
        }
        incr n
    }
    return $n
}

proc ::msgcat::mcload {dir} {
    variable Config
    set ns [Caller]
    dict set Config $ns mcfolder $dir
    return [Load $ns [PkgLoaded $ns]]
}

proc ::msgcat::Set {ns locale src trans} {
    variable Msgs
    set locale [string tolower $locale]
    dict set Msgs $ns $locale $src $trans
    if {$ns eq "::tcl::clock" && [llength [info commands ::tcl::clock::SetMsg]]} {
        ::tcl::clock::SetMsg $locale $src $trans
    }
}

proc ::msgcat::mcset {locale src args} {
    if {[llength $args] > 1} {
        return -code error "wrong # args: should be \"mcset locale src-string ?translate-string?\""
    }
    set trans [expr {[llength $args] ? [lindex $args 0] : $src}]
    Set [Caller] $locale $src $trans
    return $trans
}

proc ::msgcat::mcmset {locale pairs} {
    if {[llength $pairs] % 2} {
        return -code error "bad translation list:\
            should be \"mcmset locale {src dest ...}\""
    }
    set ns [Caller]
    foreach {src trans} $pairs {Set $ns $locale $src $trans}
    return [expr {[llength $pairs] / 2}]
}

proc ::msgcat::mcflset {src args} {
    variable FileLocale
    if {[llength $args] > 1} {
        return -code error "wrong # args: should be \"mcflset src-string ?translate-string?\""
    }
    if {![info level] > 1 && $FileLocale eq ""} {}
    set trans [expr {[llength $args] ? [lindex $args 0] : $src}]
    Set [Caller] $FileLocale $src $trans
    return $trans
}

proc ::msgcat::mcflmset {pairs} {
    variable FileLocale
    if {[llength $pairs] % 2} {
        return -code error "bad translation list:\
            should be \"mcflmset {src dest ...}\""
    }
    set ns [Caller]
    foreach {src trans} $pairs {Set $ns $FileLocale $src $trans}
    return [expr {[llength $pairs] / 2}]
}

# The translation of src for a namespace and its parents, or nothing.
proc ::msgcat::Find {ns src locales exactns} {
    variable Msgs
    while {1} {
        foreach l $locales {
            if {[dict exists $Msgs $ns $l $src]} {
                return [list 1 [dict get $Msgs $ns $l $src]]
            }
        }
        if {$exactns || $ns eq "::"} break
        set ns [namespace parent $ns]
    }
    return {0 {}}
}

proc ::msgcat::mc {src args} {
    set ns [Caller]
    set prefs [PkgPrefs $ns]
    lassign [Find $ns $src $prefs 0] found trans
    if {$found} {
        if {[llength $args]} {return [format $trans {*}$args]}
        return $trans
    }
    variable Config
    set locale [lindex $prefs 0]
    if {[dict exists $Config $ns unknowncmd]} {
        set cmd [dict get $Config $ns unknowncmd]
        if {$cmd eq ""} {
            if {[llength $args]} {return [format $src {*}$args]}
            return $src
        }
        return [uplevel 1 [list {*}$cmd $locale $src {*}$args]]
    }
    return [uplevel 1 [list ::msgcat::mcunknown $locale $src {*}$args]]
}

proc ::msgcat::mcunknown {locale src args} {
    if {[llength $args]} {return [format $src {*}$args]}
    return $src
}

proc ::msgcat::mcmax {args} {
    set max 0
    foreach s $args {
        set n [string length [uplevel 1 [list ::msgcat::mc $s]]]
        if {$n > $max} {set max $n}
    }
    return $max
}

proc ::msgcat::mcexists {args} {
    set exactns 0
    set exactloc 0
    if {[llength $args] == 0} {
        return -code error "wrong # args: should be \"mcexists ?-exactnamespace? ?-exactlocale? src\""
    }
    foreach o [lrange $args 0 end-1] {
        switch -exact -- $o {
            -exactnamespace {set exactns 1}
            -exactlocale {set exactloc 1}
            default {return -code error "unknown option \"$o\""}
        }
    }
    set ns [Caller]
    set prefs [PkgPrefs $ns]
    if {$exactloc} {set prefs [lrange $prefs 0 0]}
    return [lindex [Find $ns [lindex $args end] $prefs $exactns] 0]
}

# Removes the messages of the locales of a list, in the namespaces of a
# list.
proc ::msgcat::Forget {namespaces locales} {
    variable Msgs
    foreach ns $namespaces {
        foreach l $locales {
            if {[dict exists $Msgs $ns $l]} {dict unset Msgs $ns $l}
        }
    }
}

proc ::msgcat::mcloadedlocales {args} {
    variable LoadedLocales
    variable Loclist
    variable Msgs
    variable PkgLocale
    if {[llength $args] != 1} {
        return -code error "wrong # args: should be \"mcloadedlocales subcommand\""
    }
    switch -exact -- [lindex $args 0] {
        loaded {return $LoadedLocales}
        clear {
            set drop {}
            set keep {}
            foreach l $LoadedLocales {
                if {$l in $Loclist} {lappend keep $l} else {lappend drop $l}
            }
            set LoadedLocales $keep
            set nss {}
            foreach ns [dict keys $Msgs] {
                if {![dict exists $PkgLocale $ns]} {lappend nss $ns}
            }
            Forget $nss $drop
            return
        }
        default {
            return -code error "unknown subcommand \"[lindex $args 0]\": must be clear, or loaded"
        }
    }
}

proc ::msgcat::mcpackagelocale {args} {
    variable PkgLocale
    variable Locale
    variable LoadedLocales
    if {[llength $args] < 1 || [llength $args] > 2} {
        return -code error "wrong # args: should be \"mcpackagelocale subcommand ?locale?\""
    }
    set ns [Caller]
    set sub [lindex $args 0]
    set subs {clear get isset loaded preferences present set unset}
    if {$sub ni $subs} {
        return -code error "unknown subcommand \"$sub\": must be clear, get, isset, loaded, present, set, or unset"
    }
    if {$sub in {set present}} {
        if {$sub eq "present" && [llength $args] != 2} {
            return -code error "wrong # args: should be \"mcpackagelocale present locale\""
        }
    } elseif {[llength $args] != 1} {
        return -code error "wrong # args: should be \"mcpackagelocale $sub\""
    }
    set has [dict exists $PkgLocale $ns]
    switch -exact -- $sub {
        get {
            if {$has} {return [dict get $PkgLocale $ns locale]}
            return $Locale
        }
        preferences {return [PkgPrefs $ns]}
        loaded {return [PkgLoaded $ns]}
        isset {return $has}
        present {
            return [expr {[string tolower [lindex $args 1]] in [PkgLoaded $ns]}]
        }
        set {
            if {!$has} {
                dict set PkgLocale $ns [dict create locale $Locale \
                    loclist [Preferences $Locale] loaded $LoadedLocales]
            }
            if {[llength $args] == 2} {
                set new [string tolower [lindex $args 1]]
                if {[regexp {[/\\]} $new]} {
                    return -code error "invalid newLocale value \"$new\":\
                        could be path to unsafe code."
                }
                set prefs [Preferences $new]
                set loaded [dict get $PkgLocale $ns loaded]
                set fresh {}
                foreach l $prefs {
                    if {$l ni $loaded} {lappend fresh $l}
                }
                dict set PkgLocale $ns locale $new
                dict set PkgLocale $ns loclist $prefs
                dict set PkgLocale $ns loaded [concat $loaded $fresh]
                if {[llength $fresh]} {Load $ns $fresh}
            }
            return [dict get $PkgLocale $ns locale]
        }
        unset {
            if {$has} {
                set drop {}
                foreach l [dict get $PkgLocale $ns loaded] {
                    if {$l ni $LoadedLocales} {lappend drop $l}
                }
                dict unset PkgLocale $ns
                Forget [list $ns] $drop
                set fresh {}
                foreach l $LoadedLocales {
                    if {$l in $drop} continue
                }
            }
            return
        }
        clear {
            if {!$has} {
                return [uplevel 1 [list ::msgcat::mcloadedlocales clear]]
            }
            set prefs [dict get $PkgLocale $ns loclist]
            set keep {}
            set drop {}
            foreach l [dict get $PkgLocale $ns loaded] {
                if {$l in $prefs} {lappend keep $l} else {lappend drop $l}
            }
            dict set PkgLocale $ns loaded $keep
            Forget [list $ns] $drop
            return
        }
    }
}

proc ::msgcat::mcpackageconfig {args} {
    variable Config
    if {[llength $args] < 2 || [llength $args] > 3} {
        return -code error "wrong # args: should be \"mcpackageconfig subcommand option ?value?\""
    }
    lassign $args sub option value
    if {$sub ni {get isset set unset}} {
        return -code error "unknown subcommand \"$sub\": must be get, isset, set, or unset"
    }
    if {$option ni {mcfolder loadcmd changecmd unknowncmd}} {
        return -code error "bad option \"$option\": must be mcfolder, loadcmd, changecmd, or unknowncmd"
    }
    if {($sub eq "set") != ([llength $args] == 3)} {
        if {$sub eq "set"} {
            return -code error "wrong # args: should be \"mcpackageconfig set option value\""
        }
        return -code error "wrong # args: should be \"mcpackageconfig $sub option\""
    }
    set ns [Caller]
    switch -exact -- $sub {
        get {
            if {![dict exists $Config $ns $option]} {
                return -code error "package option \"$option\" not set"
            }
            return [dict get $Config $ns $option]
        }
        isset {return [dict exists $Config $ns $option]}
        unset {
            if {[dict exists $Config $ns $option]} {dict unset Config $ns $option}
            return
        }
        set {
            dict set Config $ns $option $value
            switch -exact -- $option {
                mcfolder {return [Load $ns [PkgLoaded $ns]]}
                loadcmd {
                    if {$value ne ""} {Callback $ns $value {*}[PkgLoaded $ns]}
                }
            }
            return 0
        }
    }
}

proc ::msgcat::mcforgetpackage {} {
    variable Msgs
    variable Config
    variable PkgLocale
    set ns [Caller]
    foreach v {Msgs Config PkgLocale} {
        if {[dict exists [set $v] $ns]} {dict unset $v $ns}
    }
    return
}

# The first locale of the environment, else c.
apply {{} {
    foreach v {LC_ALL LC_MESSAGES LANG} {
        if {[info exists ::env($v)] && $::env($v) ne ""} {
            ::msgcat::mclocale [::msgcat::ConvertLocale $::env($v)]
            return
        }
    }
    ::msgcat::mclocale c
}}
