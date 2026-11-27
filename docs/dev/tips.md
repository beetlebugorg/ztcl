# Tcl Improvement Proposals

This page lists each [TIP](https://core.tcl-lang.org/tips/doc/trunk/index.md) with the state Final, Accepted, or Voting that targets Tcl 8.7, 9.0, or 9.1. The status column gives the mode of ztcl that has the change. The index of TIPs was read on 2026-11-27. The status includes the changes of #335 and #336.

A probe script checked each script-level TIP in tclsh 9.1.0 and in ztcl with `--tcl 8.6` and `--tcl 9.1`. A status of "not checked" means that no probe covers the TIP.

| Status | Meaning |
|---|---|
| 8.6 and 9.1 | ztcl has the change in both modes. |
| 9.1 | ztcl has the change with `--tcl 9.1`. 8.6 mode follows tclsh 8.6. |
| neither | ztcl does not have the change. |
| partial | ztcl has a part of the change. The cell names the missing part. |
| n/a | The TIP is for Tk, the C API, the build, or the internals of tclsh. [C modules](cext.md) has the C module loader, which supports the stubs table of 8.6. |

The issue column links the issue of the missing part. One issue can cover more than one TIP.

| TIP | Title | Target | State | ztcl status | Issue |
|---|---|---|---|---|---|
| [765](https://core.tcl-lang.org/tips/doc/trunk/tip/765.md) | Support for off-screen rendering in macOS | 9.1 | Final | n/a: Tk |  |
| [755](https://core.tcl-lang.org/tips/doc/trunk/tip/755.md) | Add a callback for post-initialization of an interpreter | 9.1 | Final | n/a: C API |  |
| [753](https://core.tcl-lang.org/tips/doc/trunk/tip/753.md) | Windows exec and auto_execok reform | 9.1 | Final | partial: no auto_execok | #362 |
| [752](https://core.tcl-lang.org/tips/doc/trunk/tip/752.md) | New timer API without Tcl_Time | 9.1 | Final | n/a: C API |  |
| [751](https://core.tcl-lang.org/tips/doc/trunk/tip/751.md) | Rotated text for label widgets | 9.1 | Final | n/a: Tk |  |
| [750](https://core.tcl-lang.org/tips/doc/trunk/tip/750.md) | Consistent dark mode for Windows and macOS | 9.1 | Final | n/a: Tk |  |
| [747](https://core.tcl-lang.org/tips/doc/trunk/tip/747.md) | Make the selection colors of the listbox widget fully native-conform | 9.1 | Final | n/a: Tk |  |
| [746](https://core.tcl-lang.org/tips/doc/trunk/tip/746.md) | Remove "expr" behavior from lseq | 9.0 | Final | 9.1 |  |
| [745](https://core.tcl-lang.org/tips/doc/trunk/tip/745.md) | Functions from C99 | 9.1 | Final | neither | #340 |
| [744](https://core.tcl-lang.org/tips/doc/trunk/tip/744.md) | Support for long paths on Windows | 9.1 | Final | n/a: Windows paths (not checked) |  |
| [743](https://core.tcl-lang.org/tips/doc/trunk/tip/743.md) | Add native file icons to Tk | 9.1 | Final | n/a: Tk |  |
| [742](https://core.tcl-lang.org/tips/doc/trunk/tip/742.md) | Add Mouse Wheel Zoom Support to Tk Console | 9.1 | Final | n/a: Tk |  |
| [740](https://core.tcl-lang.org/tips/doc/trunk/tip/740.md) | Enhanced Treeview Widget | 9.1 | Final | n/a: Tk |  |
| [739](https://core.tcl-lang.org/tips/doc/trunk/tip/739.md) | Add a Wide.TSpinbox style to the core | 9.1 | Final | n/a: Tk |  |
| [737](https://core.tcl-lang.org/tips/doc/trunk/tip/737.md) | Expanded encoding C API | 9.1 | Final | n/a: C API |  |
| [736](https://core.tcl-lang.org/tips/doc/trunk/tip/736.md) | Scroll entry with mouse wheel | 9.1 | Final | n/a: Tk |  |
| [735](https://core.tcl-lang.org/tips/doc/trunk/tip/735.md) | Simpler List Filtering | 9.1 | Final | 9.1 |  |
| [733](https://core.tcl-lang.org/tips/doc/trunk/tip/733.md) | Add accessibility/screen reader support to Tk | 9.1 | Final | n/a: Tk |  |
| [732](https://core.tcl-lang.org/tips/doc/trunk/tip/732.md) | Changes to the Tcl script library search path | 9.1 | Final | n/a: no script library |  |
| [730](https://core.tcl-lang.org/tips/doc/trunk/tip/730.md) | Switching by Integers | 9.1 | Final | neither | #348 |
| [729](https://core.tcl-lang.org/tips/doc/trunk/tip/729.md) | Add a tk attribtable command to the core | 9.1 | Final | n/a: Tk |  |
| [728](https://core.tcl-lang.org/tips/doc/trunk/tip/728.md) | Reliable Read and Write of Child Interpreter Variables | 9.1 | Final | neither | #351 |
| [727](https://core.tcl-lang.org/tips/doc/trunk/tip/727.md) | Add a ttk::toggleswitch widget to the core | 9.1 | Final | n/a: Tk |  |
| [726](https://core.tcl-lang.org/tips/doc/trunk/tip/726.md) | Commands for Unicode normalization | 9.1 | Final | neither | #344 |
| [725](https://core.tcl-lang.org/tips/doc/trunk/tip/725.md) | Add new command ::tk::mac::GetInfoAsJSON | 9.1 | Final | n/a: Tk |  |
| [723](https://core.tcl-lang.org/tips/doc/trunk/tip/723.md) | timer ensemble for wall clock and monotonic clock events | 9.1 | Final | neither | #343 |
| [720](https://core.tcl-lang.org/tips/doc/trunk/tip/720.md) | Updated Tcl Bytecode Opcodes | 9.1 | Final | n/a: no Tcl bytecode |  |
| [719](https://core.tcl-lang.org/tips/doc/trunk/tip/719.md) | Add new states to make images of ttk::treeview and ttk::notebook customable | 9.1 | Final | n/a: Tk |  |
| [717](https://core.tcl-lang.org/tips/doc/trunk/tip/717.md) | New function: Tcl_AttemptCreateHashEntry() | 9.1 | Final | n/a: C API |  |
| [716](https://core.tcl-lang.org/tips/doc/trunk/tip/716.md) | New command "encoding user", remove UTF-8 manifest setting on Windows | 9.0.2 | Final | 9.1 |  |
| [712](https://core.tcl-lang.org/tips/doc/trunk/tip/712.md) | Add "positive" options to the subst command | 9.1 | Final | neither | #349 |
| [711](https://core.tcl-lang.org/tips/doc/trunk/tip/711.md) | New function: Tcl_IsEmpty() | 9.1 | Final | n/a: C API |  |
| [707](https://core.tcl-lang.org/tips/doc/trunk/tip/707.md) | Add new Tcl_Obj internal representation to hold pointer + length | 8.7 | Final | n/a: C API |  |
| [706](https://core.tcl-lang.org/tips/doc/trunk/tip/706.md) | Expose three Tk "In Context" functions via stubs table | 9.0.1 | Final | n/a: Tk |  |
| [704](https://core.tcl-lang.org/tips/doc/trunk/tip/704.md) | extend Tk_CanvasTextInfo | 9.1 | Final | n/a: Tk |  |
| [701](https://core.tcl-lang.org/tips/doc/trunk/tip/701.md) | C API for tilde substitution in paths | 8.7 | Final | n/a: C API |  |
| [699](https://core.tcl-lang.org/tips/doc/trunk/tip/699.md) | Eliminate encoding alias "binary"; provide introspection for binary channels. | 9.0 | Final | partial: no chan isbinary, binary is still listed | #353 |
| [698](https://core.tcl-lang.org/tips/doc/trunk/tip/698.md) | Handle negative screen distances | 9.1 | Final | n/a: Tk |  |
| [697](https://core.tcl-lang.org/tips/doc/trunk/tip/697.md) | 32-bit truncation in format and scan | 9.0 | Final | neither | #358 |
| [696](https://core.tcl-lang.org/tips/doc/trunk/tip/696.md) | Reserve range of return codes for Tcl's own use | 9.0 | Final | n/a: a reservation |  |
| [693](https://core.tcl-lang.org/tips/doc/trunk/tip/693.md) | Restart the changes files | 8.7 | Final | n/a: build or process |  |
| [692](https://core.tcl-lang.org/tips/doc/trunk/tip/692.md) | Revise Tcl_GetAliasObj, remove Tcl_GetAlias() | 9.0 | Final | n/a: C API |  |
| [690](https://core.tcl-lang.org/tips/doc/trunk/tip/690.md) | Make "clock scan -valid 1" the default | 9.0 | Final | neither | #343 |
| [688](https://core.tcl-lang.org/tips/doc/trunk/tip/688.md) | clock command revision and speedup | 8.7 | Final | partial: no weekdays unit | #343 |
| [687](https://core.tcl-lang.org/tips/doc/trunk/tip/687.md) | locale support for word handling in text and entry | 9.1 | Final | n/a: Tk |  |
| [686](https://core.tcl-lang.org/tips/doc/trunk/tip/686.md) | Make NextWord/SelectNextWord behavior platform-independant | 8.7 | Final | n/a: Tk |  |
| [684](https://core.tcl-lang.org/tips/doc/trunk/tip/684.md) | Add Support for Touchpad Scrolling to Tk | 8.7 | Final | n/a: Tk |  |
| [683](https://core.tcl-lang.org/tips/doc/trunk/tip/683.md) | Remove legacy "pack" and "scrollbar" syntax | 9.0 | Final | n/a: Tk |  |
| [681](https://core.tcl-lang.org/tips/doc/trunk/tip/681.md) | Ttk "size"-related options | 9.0 | Final | n/a: Tk |  |
| [678](https://core.tcl-lang.org/tips/doc/trunk/tip/678.md) | Better API for Detached Treeview Items | 9.0 | Final | n/a: Tk |  |
| [677](https://core.tcl-lang.org/tips/doc/trunk/tip/677.md) | Constant Variables | 9.0 | Final | neither | #342 |
| [675](https://core.tcl-lang.org/tips/doc/trunk/tip/675.md) | Control cursor blinking cycle in Ttk widgets. | 8.7 | Final | n/a: Tk |  |
| [673](https://core.tcl-lang.org/tips/doc/trunk/tip/673.md) | Remove deprecated [trace] subcommands | 9.0 | Final | neither | #359 |
| [672](https://core.tcl-lang.org/tips/doc/trunk/tip/672.md) | Extend $ substitution to include expressions as $((expression)) | 9.1 | Voting | neither |  |
| [670](https://core.tcl-lang.org/tips/doc/trunk/tip/670.md) | Simple Extra Procedures for File Access | 8.7 | Final | neither | #352 |
| [666](https://core.tcl-lang.org/tips/doc/trunk/tip/666.md) | Change ptrdiff_t → Tcl_Size in Tcl 8.7 (and 9.0) | 8.7 | Final | n/a: C API |  |
| [665](https://core.tcl-lang.org/tips/doc/trunk/tip/665.md) | Remove support for internal utf-16 for Tcl 8.7 (and 9.0) | 8.7 | Final | n/a: C API |  |
| [663](https://core.tcl-lang.org/tips/doc/trunk/tip/663.md) | Cease distribution of the ChangeLog files | 8.7 | Final | n/a: build or process |  |
| [661](https://core.tcl-lang.org/tips/doc/trunk/tip/661.md) | Disable the Tcl 8 compatibility macros in Tcl 9 by default | 9.0 | Final | n/a: C API |  |
| [660](https://core.tcl-lang.org/tips/doc/trunk/tip/660.md) | Use signed types for lengths and indices | 8.7 | Final | n/a: C API |  |
| [658](https://core.tcl-lang.org/tips/doc/trunk/tip/658.md) | Attach identifiers to Tk menu entries | 8.7 | Final | n/a: Tk |  |
| [657](https://core.tcl-lang.org/tips/doc/trunk/tip/657.md) | Make "-profile strict" the default in Tcl 9.0 | 9.0 | Final | 9.1 |  |
| [656](https://core.tcl-lang.org/tips/doc/trunk/tip/656.md) | A revised proposal for encodings | 8.7 | Final | 9.1 |  |
| [655](https://core.tcl-lang.org/tips/doc/trunk/tip/655.md) | Support the styleMask property for NSWindow and NSPanel in Aqua | 8.7 | Final | n/a: Tk |  |
| [653](https://core.tcl-lang.org/tips/doc/trunk/tip/653.md) | Handle consumed data of channel commands in case of encoding errors | 8.7 | Final | not checked |  |
| [652](https://core.tcl-lang.org/tips/doc/trunk/tip/652.md) | Remove  "string is unicode" and Tcl_CharIsUnicode" | 8.7 | Final | 8.6 and 9.1 |  |
| [651](https://core.tcl-lang.org/tips/doc/trunk/tip/651.md) | Expose TclDStringToObj via stubs table | 8.7 | Final | n/a: C API |  |
| [650](https://core.tcl-lang.org/tips/doc/trunk/tip/650.md) | New function Tcl_GetWideUIntFromObj() | 8.7 | Final | n/a: C API |  |
| [649](https://core.tcl-lang.org/tips/doc/trunk/tip/649.md) | Expose additional list functionality in the C API | 9.1 | Final | n/a: C API |  |
| [648](https://core.tcl-lang.org/tips/doc/trunk/tip/648.md) | New functions Tcl_NewWideUIntObj()/Tcl_SetWideUIntObj() | 8.7 | Final | n/a: C API |  |
| [647](https://core.tcl-lang.org/tips/doc/trunk/tip/647.md) | Change Tk_ConfigureWidgets signature, abandon TK_CONFIG_OBJS | 9.0 | Final | n/a: Tk |  |
| [646](https://core.tcl-lang.org/tips/doc/trunk/tip/646.md) | Change -eofchar handling | 8.7 | Final | partial: -eofchar takes a list | #354 |
| [645](https://core.tcl-lang.org/tips/doc/trunk/tip/645.md) | ttk color palette support | 8.7 | Final | n/a: Tk |  |
| [644](https://core.tcl-lang.org/tips/doc/trunk/tip/644.md) | Make Tcl_ObjType extensible | 9.0 | Final | n/a: C API |  |
| [643](https://core.tcl-lang.org/tips/doc/trunk/tip/643.md) | Provide a public API to retrieve nul terminator length for an encoding | 8.7 | Final | n/a: C API |  |
| [642](https://core.tcl-lang.org/tips/doc/trunk/tip/642.md) | Let TK_OPTION_BOOL/TK_OPTION_STRING_TABLE handle (C99) bool/enum. | 8.7 | Final | n/a: Tk |  |
| [641](https://core.tcl-lang.org/tips/doc/trunk/tip/641.md) | Let Tcl_GetBoolean(FromObj) handle (C99) bool. | 8.7 | Final | n/a: C API |  |
| [640](https://core.tcl-lang.org/tips/doc/trunk/tip/640.md) | Remove Tcl_SaveResult | 9.0 | Final | n/a: C API |  |
| [639](https://core.tcl-lang.org/tips/doc/trunk/tip/639.md) | Include the mac_styles features in Tk 8.7 | 8.7 | Final | n/a: Tk |  |
| [638](https://core.tcl-lang.org/tips/doc/trunk/tip/638.md) | New public routines Tcl_GetNumber(FromObj) | 8.7 | Final | n/a: C API |  |
| [637](https://core.tcl-lang.org/tips/doc/trunk/tip/637.md) | Make [glob] always -nocomplain | 9.0 | Final | 9.1 |  |
| [636](https://core.tcl-lang.org/tips/doc/trunk/tip/636.md) | Expand List Flexibility with Abstract List Tcl_Obj Type | 9.0 | Final | n/a: internal |  |
| [634](https://core.tcl-lang.org/tips/doc/trunk/tip/634.md) | Remove inconsistency in variable tracing of an array | 9.0 | Final | not checked |  |
| [633](https://core.tcl-lang.org/tips/doc/trunk/tip/633.md) | configure channel about channel encoding error reporting mode | 8.7 | Final | 9.1 |  |
| [632](https://core.tcl-lang.org/tips/doc/trunk/tip/632.md) | return gif animated metadata | 8.7 | Final | n/a: Tk |  |
| [631](https://core.tcl-lang.org/tips/doc/trunk/tip/631.md) | ledit - a generalized insert/delete command for list variables | 8.7 | Final | 9.1 |  |
| [630](https://core.tcl-lang.org/tips/doc/trunk/tip/630.md) | TclOO commands > 2^31 (for 8.7) | 8.7 | Final | n/a: C API |  |
| [629](https://core.tcl-lang.org/tips/doc/trunk/tip/629.md) | Add a lseq (formally "range") command to the core of list commands | 8.7 | Final | 9.1 |  |
| [628](https://core.tcl-lang.org/tips/doc/trunk/tip/628.md) | Shared 8.7/9.0 build environment | 9.0 | Final | n/a: build or process |  |
| [627](https://core.tcl-lang.org/tips/doc/trunk/tip/627.md) | New functions for handling commands > 2^31 elements (for 8.7) | 8.7 | Final | n/a: C API |  |
| [626](https://core.tcl-lang.org/tips/doc/trunk/tip/626.md) | Command arguments > 2^31 elements | 9.1 | Final | partial: 32-bit list index | #360 |
| [625](https://core.tcl-lang.org/tips/doc/trunk/tip/625.md) | Re-implementation of lists | 8.7 | Final | n/a: internal |  |
| [624](https://core.tcl-lang.org/tips/doc/trunk/tip/624.md) | Deprecate Tcl_MakeSafe | 8.7 | Final | n/a: C API |  |
| [622](https://core.tcl-lang.org/tips/doc/trunk/tip/622.md) | Full Unicode for Tcl 8.7 | 8.7 | Final | 8.6 and 9.1 |  |
| [621](https://core.tcl-lang.org/tips/doc/trunk/tip/621.md) | Glyph clustering for Tk | 8.7 | Final | n/a: Tk |  |
| [620](https://core.tcl-lang.org/tips/doc/trunk/tip/620.md) | Treeview cell padding. | 8.7 | Final | n/a: Tk |  |
| [619](https://core.tcl-lang.org/tips/doc/trunk/tip/619.md) | New TCL_COMBINE flag for Tcl_UniCharToUtf() | 9.0 | Final | n/a: C API |  |
| [618](https://core.tcl-lang.org/tips/doc/trunk/tip/618.md) | New Tcl_GetBool* functions with TCL_NULL_OK flag | 8.7 | Final | n/a: C API |  |
| [617](https://core.tcl-lang.org/tips/doc/trunk/tip/617.md) | Tcl_WCharLen/Tcl_Char16Len | 8.7 | Final | n/a: C API |  |
| [616](https://core.tcl-lang.org/tips/doc/trunk/tip/616.md) | Tcl lists > 2^31 elements | 9.0 | Final | partial: 32-bit list index | #360 |
| [613](https://core.tcl-lang.org/tips/doc/trunk/tip/613.md) | New INDEX_NULL_OK flag for Tcl_GetIndexFromObj*() | 8.7 | Final | n/a: C API |  |
| [610](https://core.tcl-lang.org/tips/doc/trunk/tip/610.md) | Icon Badges | 8.7 | Final | n/a: Tk |  |
| [609](https://core.tcl-lang.org/tips/doc/trunk/tip/609.md) | Enhance Tcl_ThreadQueueEvent() | 8.7 | Final | n/a: C API |  |
| [607](https://core.tcl-lang.org/tips/doc/trunk/tip/607.md) | -failindex option for encoding convertto/convertfrom | 8.7 | Final | 9.1 |  |
| [606](https://core.tcl-lang.org/tips/doc/trunk/tip/606.md) | Export more private Tk functions | 8.7 | Final | n/a: Tk |  |
| [605](https://core.tcl-lang.org/tips/doc/trunk/tip/605.md) | Function to get class name from object | 8.7 | Final | n/a: C API |  |
| [604](https://core.tcl-lang.org/tips/doc/trunk/tip/604.md) | Printing Support for Text and Canvas Widgets | 8.7 | Final | n/a: Tk |  |
| [603](https://core.tcl-lang.org/tips/doc/trunk/tip/603.md) | Get 'stat' Information of Open Files | 8.7 | Final | neither | #352 |
| [602](https://core.tcl-lang.org/tips/doc/trunk/tip/602.md) | Remove tilde expansion in file paths. | 9.0 | Final | partial: no file home, file tildeexpand | #352 |
| [599](https://core.tcl-lang.org/tips/doc/trunk/tip/599.md) | Extended build information | 8.7 | Final | neither | #351 |
| [598](https://core.tcl-lang.org/tips/doc/trunk/tip/598.md) | export TclWinConvertError | 8.7 | Final | n/a: C API |  |
| [597](https://core.tcl-lang.org/tips/doc/trunk/tip/597.md) | "string is unicode" and better utf-8/utf-16/cesu-8 encodings | 8.7 | Final | partial: no utf-16, ucs-2, cesu-8 | #353 |
| [596](https://core.tcl-lang.org/tips/doc/trunk/tip/596.md) | Stubs support for Embedding Tcl in other applications | 9.0 | Final | n/a: C API |  |
| [595](https://core.tcl-lang.org/tips/doc/trunk/tip/595.md) | Unicode-aware/case-sensitive Loadable Library handling | 9.0 | Final | n/a: C API |  |
| [594](https://core.tcl-lang.org/tips/doc/trunk/tip/594.md) | Modernize "file stat" interface | 8.7 | Final | partial: no dict form of file stat | #352 |
| [592](https://core.tcl-lang.org/tips/doc/trunk/tip/592.md) | Stop support for Windows XP, Server 2003, Vista, Server 2008 | 8.7 | Final | n/a: build or process |  |
| [591](https://core.tcl-lang.org/tips/doc/trunk/tip/591.md) | Rotate ttk::notebook window with mousewheel on tab | 8.7 | Final | n/a: Tk |  |
| [590](https://core.tcl-lang.org/tips/doc/trunk/tip/590.md) | Recommend lowercase Package Names | 8.7 | Final | n/a: build or process |  |
| [588](https://core.tcl-lang.org/tips/doc/trunk/tip/588.md) | Unicode for (X11) keysyms | 8.7 | Final | n/a: Tk |  |
| [587](https://core.tcl-lang.org/tips/doc/trunk/tip/587.md) | Default utf-8 for source command | 9.0 | Final | 8.6 and 9.1 |  |
| [586](https://core.tcl-lang.org/tips/doc/trunk/tip/586.md) | C String Parsing Support for binary scan | 8.7 | Final | neither | #358 |
| [585](https://core.tcl-lang.org/tips/doc/trunk/tip/585.md) | Promote the INDEX_TEMP_TABLE flag of Tcl_GetIndexFromObj*() to the public interface | 8.7 | Final | n/a: C API |  |
| [584](https://core.tcl-lang.org/tips/doc/trunk/tip/584.md) | Better introspection for ttk | 8.7 | Final | n/a: Tk |  |
| [582](https://core.tcl-lang.org/tips/doc/trunk/tip/582.md) | Comments in Expressions | 8.7 | Final | neither | #341 |
| [580](https://core.tcl-lang.org/tips/doc/trunk/tip/580.md) | Export Tk_GetDoublePixelsFromObj and 5 more | 8.7 | Final | n/a: Tk |  |
| [579](https://core.tcl-lang.org/tips/doc/trunk/tip/579.md) | Improved auto_path for Safe Base interpreters | 8.7 | Final | n/a: no Safe Base |  |
| [578](https://core.tcl-lang.org/tips/doc/trunk/tip/578.md) | Death to TCL_DBGX | 8.7 | Final | n/a: build or process |  |
| [577](https://core.tcl-lang.org/tips/doc/trunk/tip/577.md) | Enhanced index values for Tk | 8.7 | Final | n/a: Tk |  |
| [575](https://core.tcl-lang.org/tips/doc/trunk/tip/575.md) | Switchable Tcl_UtfCharComplete()/Tcl_UtfNext()/Tcl_UtfPrev() | 8.7 | Final | n/a: C API |  |
| [574](https://core.tcl-lang.org/tips/doc/trunk/tip/574.md) | Add a 'tag delete' command to the ttk::treeview widget | 8.7 | Final | n/a: Tk |  |
| [569](https://core.tcl-lang.org/tips/doc/trunk/tip/569.md) | Eliminate Comments That Serve Lint | 8.7 | Final | n/a: build or process |  |
| [568](https://core.tcl-lang.org/tips/doc/trunk/tip/568.md) | Revise ByteArray Routines To Support Proper Value Extraction | 9.0 | Final | n/a: C API |  |
| [567](https://core.tcl-lang.org/tips/doc/trunk/tip/567.md) | Add Operation to Support Set-like Slots | 8.7 | Final | neither | #356 |
| [565](https://core.tcl-lang.org/tips/doc/trunk/tip/565.md) | Gracefully ignore non-existent tags in canvas raise/lower | 8.7 | Final | n/a: Tk |  |
| [564](https://core.tcl-lang.org/tips/doc/trunk/tip/564.md) | Specify ttk font sizes in points on X11 | 8.7 | Final | n/a: Tk |  |
| [563](https://core.tcl-lang.org/tips/doc/trunk/tip/563.md) | Scrollwheel on Horizontal Scrollbar Scrolls Without Shift too | 8.7 | Final | n/a: Tk |  |
| [562](https://core.tcl-lang.org/tips/doc/trunk/tip/562.md) | Deprecate channel types 1-4 | 8.7 | Final | n/a: C API |  |
| [559](https://core.tcl-lang.org/tips/doc/trunk/tip/559.md) | Eliminate public routine Tcl_FreeResult | 9.0 | Final | n/a: C API |  |
| [558](https://core.tcl-lang.org/tips/doc/trunk/tip/558.md) | Basic Configure Support for TclOO | 8.7 | Final | neither | #356 |
| [557](https://core.tcl-lang.org/tips/doc/trunk/tip/557.md) | C++ support for Tcl | 8.7 | Final | n/a: C API |  |
| [552](https://core.tcl-lang.org/tips/doc/trunk/tip/552.md) | Extended treeview functionality. | 8.7 | Final | n/a: Tk |  |
| [551](https://core.tcl-lang.org/tips/doc/trunk/tip/551.md) | Permit underscore in numerical literals in source code | 8.7 | Final | neither | #341 |
| [548](https://core.tcl-lang.org/tips/doc/trunk/tip/548.md) | Support wchar_t conversion functions and deprecate Tcl_WinUtfToTChar() and Tcl_WinTCharToUtf() | 8.7 | Final | n/a: C API |  |
| [547](https://core.tcl-lang.org/tips/doc/trunk/tip/547.md) | New encodings: UTF-16, UCS-2 | 8.7 | Final | neither | #353 |
| [545](https://core.tcl-lang.org/tips/doc/trunk/tip/545.md) | image photo SVG options: remove -unit and add target height/width option | 8.7 | Final | n/a: Tk |  |
| [544](https://core.tcl-lang.org/tips/doc/trunk/tip/544.md) | Export TclGetIntForIndex() | 8.7 | Final | n/a: C API |  |
| [543](https://core.tcl-lang.org/tips/doc/trunk/tip/543.md) | Eliminate TCL_INTERP_DESTROYED flag value | 9.0 | Final | n/a: C API |  |
| [542](https://core.tcl-lang.org/tips/doc/trunk/tip/542.md) | Support for switchable Full Unicode support | 8.7 | Final | n/a: C API |  |
| [538](https://core.tcl-lang.org/tips/doc/trunk/tip/538.md) | Externalize libtommath | 8.7 | Final | n/a: build or process |  |
| [537](https://core.tcl-lang.org/tips/doc/trunk/tip/537.md) | Enable 64-bit indexes in regexp matching | 9.0 | Final | n/a: internal |  |
| [529](https://core.tcl-lang.org/tips/doc/trunk/tip/529.md) | Add metadata dictionary property to tk photo image | 8.7 | Final | n/a: Tk |  |
| [528](https://core.tcl-lang.org/tips/doc/trunk/tip/528.md) | Deprecate Tk_Offset() | 8.7 | Final | n/a: Tk |  |
| [527](https://core.tcl-lang.org/tips/doc/trunk/tip/527.md) | New measurement facilities in TCL: New command timerate | 8.7 | Final | 8.6 and 9.1 |  |
| [524](https://core.tcl-lang.org/tips/doc/trunk/tip/524.md) | Custom Definition Dialects for TclOO | 8.7 | Final | neither | #356 |
| [523](https://core.tcl-lang.org/tips/doc/trunk/tip/523.md) | New lpop command | 8.7 | Final | 9.1 |  |
| [522](https://core.tcl-lang.org/tips/doc/trunk/tip/522.md) | Test error codes with Tcltest | 8.7 | Final | n/a: no tcltest package |  |
| [521](https://core.tcl-lang.org/tips/doc/trunk/tip/521.md) | Floating Point Classification Functions | 8.7 | Final | neither | #340 |
| [519](https://core.tcl-lang.org/tips/doc/trunk/tip/519.md) | Inline export/unexport option to TclOO method definition | 8.7 | Final | neither | #356 |
| [518](https://core.tcl-lang.org/tips/doc/trunk/tip/518.md) | Virtual Event when Last Child is not Managed any more | 8.7 | Final | n/a: Tk |  |
| [517](https://core.tcl-lang.org/tips/doc/trunk/tip/517.md) | Add -activerelief Configuration Option to the menu widget | 8.7 | Final | n/a: Tk |  |
| [516](https://core.tcl-lang.org/tips/doc/trunk/tip/516.md) | More OO Slot Operations | 8.7 | Final | neither | #356 |
| [515](https://core.tcl-lang.org/tips/doc/trunk/tip/515.md) | Level Value Reform | 8.7 | Final | not checked |  |
| [514](https://core.tcl-lang.org/tips/doc/trunk/tip/514.md) | Platform differences in handling int/wide | 8.7 | Final | neither: int() keeps the low 64 bits, as in 8.6 | #361 |
| [512](https://core.tcl-lang.org/tips/doc/trunk/tip/512.md) | No stub for Tcl_SetExitProc() | 8.7 | Final | n/a: C API |  |
| [511](https://core.tcl-lang.org/tips/doc/trunk/tip/511.md) | Implement Tcl_AsyncMarkFromSignal() | 8.7 | Final | n/a: C API |  |
| [509](https://core.tcl-lang.org/tips/doc/trunk/tip/509.md) | Implement reentrant mutexes on all platforms | 8.7 | Final | n/a: C API |  |
| [508](https://core.tcl-lang.org/tips/doc/trunk/tip/508.md) | New subcommand [array default] | 8.7 | Final | neither | #346 |
| [507](https://core.tcl-lang.org/tips/doc/trunk/tip/507.md) | Include simple SVG support with nanosvg | 8.7 | Final | n/a: Tk |  |
| [506](https://core.tcl-lang.org/tips/doc/trunk/tip/506.md) | Purge RefCount Macros | 8.7 | Final | n/a: C API |  |
| [504](https://core.tcl-lang.org/tips/doc/trunk/tip/504.md) | New subcommand [string insert] | 8.7 | Final | 9.1 |  |
| [503](https://core.tcl-lang.org/tips/doc/trunk/tip/503.md) | End Tcl 8.3 Source Compatibility Support | 8.7 | Final | n/a: C API |  |
| [502](https://core.tcl-lang.org/tips/doc/trunk/tip/502.md) | Index Value Reform | 8.7 | Final | 8.6 and 9.1 |  |
| [501](https://core.tcl-lang.org/tips/doc/trunk/tip/501.md) | string is dict | 8.7 | Final | 9.1 |  |
| [500](https://core.tcl-lang.org/tips/doc/trunk/tip/500.md) | Private Methods and Variables in TclOO | 8.7 | Final | neither | #356 |
| [499](https://core.tcl-lang.org/tips/doc/trunk/tip/499.md) | Custom locale search list for msgcat | 8.7 | Final | neither | #357 |
| [497](https://core.tcl-lang.org/tips/doc/trunk/tip/497.md) | Full support for Unicode planes 1-16. | 9.0 | Final | 8.6 and 9.1 |  |
| [496](https://core.tcl-lang.org/tips/doc/trunk/tip/496.md) | Display hints in ::entry ::spinbox ::ttk::entry ::ttk::spinbox and ::ttk::combobox | 8.7 | Final | n/a: Tk |  |
| [494](https://core.tcl-lang.org/tips/doc/trunk/tip/494.md) | More use of size_t/ptrdiff_t in Tcl 9 | 9.0 | Final | n/a: C API |  |
| [493](https://core.tcl-lang.org/tips/doc/trunk/tip/493.md) | Cease Distribution of http 1.0 | 8.7 | Final | n/a: build or process |  |
| [492](https://core.tcl-lang.org/tips/doc/trunk/tip/492.md) | Introspection for 'tk busy' | 8.7 | Final | n/a: Tk |  |
| [491](https://core.tcl-lang.org/tips/doc/trunk/tip/491.md) | Threading Support: phasing out non-threaded builds | 8.7 | Final | n/a: build or process |  |
| [490](https://core.tcl-lang.org/tips/doc/trunk/tip/490.md) | msgcat for TclOO | 8.7 | Final | neither | #357 |
| [489](https://core.tcl-lang.org/tips/doc/trunk/tip/489.md) | Add image widget command to the Tk canvas | 8.7 | Final | n/a: Tk |  |
| [488](https://core.tcl-lang.org/tips/doc/trunk/tip/488.md) | Remove tcl_precision | 9.0 | Final | 9.1 |  |
| [487](https://core.tcl-lang.org/tips/doc/trunk/tip/487.md) | Stop support for Pre-XP Windows | 8.7 | Final | n/a: build or process |  |
| [485](https://core.tcl-lang.org/tips/doc/trunk/tip/485.md) | Remove Deprecated API | 9.0 | Final | n/a: C API |  |
| [484](https://core.tcl-lang.org/tips/doc/trunk/tip/484.md) | Merge 'int' and 'wideInt' Obj-type to a single 'int' | 8.7 | Final | n/a: internal |  |
| [483](https://core.tcl-lang.org/tips/doc/trunk/tip/483.md) | Improved TIP #59 implementation for Tk | 8.7 | Final | n/a: Tk |  |
| [482](https://core.tcl-lang.org/tips/doc/trunk/tip/482.md) | Record Tk demo directory information | 8.7 | Final | n/a: Tk |  |
| [481](https://core.tcl-lang.org/tips/doc/trunk/tip/481.md) | Tcl_GetStringFromObj() with ptrdiff_t length parameter | 8.7 | Final | n/a: C API |  |
| [478](https://core.tcl-lang.org/tips/doc/trunk/tip/478.md) | Add Expected Class Level Behaviors to oo::class | 8.7 | Final | neither | #356 |
| [476](https://core.tcl-lang.org/tips/doc/trunk/tip/476.md) | Scan/Printf format consistency | 8.7 | Final | 8.6 and 9.1 |  |
| [474](https://core.tcl-lang.org/tips/doc/trunk/tip/474.md) | Treat the mouse wheel events in a uniform way | 8.7 | Final | n/a: Tk |  |
| [472](https://core.tcl-lang.org/tips/doc/trunk/tip/472.md) | Add Support for 0d Radix Prefix to Integer Literals | 8.7 | Final | neither | #341 |
| [470](https://core.tcl-lang.org/tips/doc/trunk/tip/470.md) | Reliable Access to OO Definition Context Object | 8.7 | Final | 8.6 and 9.1 |  |
| [468](https://core.tcl-lang.org/tips/doc/trunk/tip/468.md) | Support Passing TCP listen Backlog Size Option to TCP Socket Creation | 8.7 | Final | neither | #354 |
| [465](https://core.tcl-lang.org/tips/doc/trunk/tip/465.md) | Change Rule 8 of the Dodekalogue to Cut Some Corner Cases | 9.0 | Final | not checked |  |
| [463](https://core.tcl-lang.org/tips/doc/trunk/tip/463.md) | Command-Driven Substitutions for regsub | 8.7 | Final | neither | #349 |
| [462](https://core.tcl-lang.org/tips/doc/trunk/tip/462.md) | Add New [::tcl::process] Ensemble for Subprocess Management | 8.7 | Final | neither | #345 |
| [461](https://core.tcl-lang.org/tips/doc/trunk/tip/461.md) | Separate Numeric and String Comparison Operators | 8.7 | Final | neither | #341 |
| [459](https://core.tcl-lang.org/tips/doc/trunk/tip/459.md) | Tcl Package Introspection Improvements | 8.7 | Final | neither | #351 |
| [458](https://core.tcl-lang.org/tips/doc/trunk/tip/458.md) | Add Support for epoll() and kqueue() in the Notifier | 8.7 | Final | n/a: internal |  |
| [456](https://core.tcl-lang.org/tips/doc/trunk/tip/456.md) | Extend the C API to Support Passing Options to TCP Server Creation | 8.7 | Final | n/a: C API |  |
| [455](https://core.tcl-lang.org/tips/doc/trunk/tip/455.md) | Extensions to [vwait]: Variable Sets and Scripted Access to Tcl_DoOneEvent | 8.7 | Final | neither | #355 |
| [449](https://core.tcl-lang.org/tips/doc/trunk/tip/449.md) | [text] undo/redo to Return Range of Characters | 8.7 | Final | n/a: Tk |  |
| [447](https://core.tcl-lang.org/tips/doc/trunk/tip/447.md) | Execution Time Verbosity Levels in tcltest::configure | 8.7 | Final | n/a: no tcltest package |  |
| [445](https://core.tcl-lang.org/tips/doc/trunk/tip/445.md) | Tcl_ObjType Utility Routines | 8.7 | Final | n/a: C API |  |
| [444](https://core.tcl-lang.org/tips/doc/trunk/tip/444.md) | Add "weekdays" unit in clock add | 8.7 | Final | neither | #343 |
| [442](https://core.tcl-lang.org/tips/doc/trunk/tip/442.md) | Display text in progressbars | 8.7 | Final | n/a: Tk |  |
| [431](https://core.tcl-lang.org/tips/doc/trunk/tip/431.md) | Add 'tempdir' Subcommand to 'file' | 8.7 | Final | neither | #352 |
| [430](https://core.tcl-lang.org/tips/doc/trunk/tip/430.md) | Add basic ZIP archive support to Tcl | 8.7 | Final | partial: 9.1 adds subcommands | #350 |
| [426](https://core.tcl-lang.org/tips/doc/trunk/tip/426.md) | Determining the "Type" of Commands | 8.7 | Final | neither | #351 |
| [425](https://core.tcl-lang.org/tips/doc/trunk/tip/425.md) | Correct use of UTF-8 in Panic Callback (Windows only) | 8.7 | Final | n/a: C API |  |
| [422](https://core.tcl-lang.org/tips/doc/trunk/tip/422.md) | Don't Use stdarg.h/va_list in Public API | 9.0 | Final | n/a: C API |  |
| [421](https://core.tcl-lang.org/tips/doc/trunk/tip/421.md) | A Command for Iterating Over Arrays | 8.7 | Final | 9.1 |  |
| [415](https://core.tcl-lang.org/tips/doc/trunk/tip/415.md) | Enable Easy Creation of Circular Arc Segments | 8.7 | Final | n/a: Tk |  |
| [414](https://core.tcl-lang.org/tips/doc/trunk/tip/414.md) | Add (back) Tcl_InitSubsystems as Public API | 8.7 | Final | n/a: C API |  |
| [406](https://core.tcl-lang.org/tips/doc/trunk/tip/406.md) | "C" is for Cookie | 8.7 | Final | n/a: no http package |  |
| [402](https://core.tcl-lang.org/tips/doc/trunk/tip/402.md) | General Platform UNC Support | 8.7 | Final | n/a: Windows paths (not checked) |  |
| [389](https://core.tcl-lang.org/tips/doc/trunk/tip/389.md) | Full support for Unicode 10.0 and later (part 1) | 8.7 | Final | 8.6 and 9.1 |  |
| [383](https://core.tcl-lang.org/tips/doc/trunk/tip/383.md) | Injecting Code into Suspended Coroutines | 8.7 | Final | neither | #355 |
| [367](https://core.tcl-lang.org/tips/doc/trunk/tip/367.md) | A Command to Remove Elements from a List | 8.7 | Final | 9.1 |  |
| [351](https://core.tcl-lang.org/tips/doc/trunk/tip/351.md) | Add Striding Support to lsearch | 8.7 | Final | neither | #347 |
| [345](https://core.tcl-lang.org/tips/doc/trunk/tip/345.md) | Kill the 'identity' Encoding | 8.7 | Final | partial: identity is still listed | #353 |
| [344](https://core.tcl-lang.org/tips/doc/trunk/tip/344.md) | Bring TCP_NODELAY and SO_KEEPALIVE to socket options | 8.7 | Final | neither | #354 |
| [342](https://core.tcl-lang.org/tips/doc/trunk/tip/342.md) | Dict Get With Default | 8.7 | Final | 9.1 |  |
| [325](https://core.tcl-lang.org/tips/doc/trunk/tip/325.md) | System Tray and System Notification Access | 8.7 | Final | n/a: Tk |  |
| [312](https://core.tcl-lang.org/tips/doc/trunk/tip/312.md) | Add More Link Types | 8.7 | Final | n/a: C API |  |
| [278](https://core.tcl-lang.org/tips/doc/trunk/tip/278.md) | Fix Variable Name Resolution Quirks | 9.0 | Final | 9.1 |  |
| [262](https://core.tcl-lang.org/tips/doc/trunk/tip/262.md) | Background Images for Frames | 8.7 | Final | n/a: Tk |  |
| [220](https://core.tcl-lang.org/tips/doc/trunk/tip/220.md) | Escalate Privileges in VFS Close Callback | 8.7 | Final | n/a: C API |  |
| [166](https://core.tcl-lang.org/tips/doc/trunk/tip/166.md) | Reading and Writing the Photo Image Alpha Channel | 8.7 | Final | n/a: Tk |  |
| [164](https://core.tcl-lang.org/tips/doc/trunk/tip/164.md) | Add Rotate Subcommand to the Canvas Widget | 8.7 | Final | n/a: Tk |  |
| [161](https://core.tcl-lang.org/tips/doc/trunk/tip/161.md) | Change Default for Menu's -tearoff Option to False | 8.7 | Final | n/a: Tk |  |
| [160](https://core.tcl-lang.org/tips/doc/trunk/tip/160.md) | Improvements to Terminal and Serial Channel Handling | 8.7 | Final | neither | #354 |
| [114](https://core.tcl-lang.org/tips/doc/trunk/tip/114.md) | Eliminate Octal Parsing of Leading Zero Integer Strings | 9.0 | Final | 9.1 |  |

## Issues

| Issue | Scope |
|---|---|
| #340 | The math functions of Tcl 8.7 and 9.1 (TIP 521, 745) |
| #341 | The operators lt, le, gt, ge, comments, and number forms in expr (TIP 461, 472, 551, 582) |
| #342 | const, info constant, and info consts (TIP 677) |
| #343 | The timer command and the clock changes of 8.7 and 9.0 (TIP 444, 688, 690, 723) |
| #344 | The unicode command (TIP 726) |
| #345 | The tcl::process ensemble (TIP 462) |
| #346 | array default (TIP 508) |
| #347 | lsearch -stride (TIP 351) |
| #348 | switch -integer (TIP 730) |
| #349 | subst -backslashes, -commands, -variables, and regsub -command (TIP 463, 712) |
| #350 | zipfs canonical, find, mkzip, mountdata, and the other subcommands of 9.1 (TIP 430) |
| #351 | info cmdtype, package files, tcl::build-info, and interp set (TIP 426, 459, 599, 728) |
| #352 | file tempdir, file home, file tildeexpand, readFile, file stat, and chan -stat (TIP 431, 594, 602, 603, 670) |
| #353 | The encodings and removals of Tcl 8.7 and 9.0 (TIP 345, 547, 597, 699) |
| #354 | Socket and terminal channel options (TIP 160, 344, 468, 646) |
| #355 | vwait options, coroinject, and coroprobe (TIP 383, 455) |
| #356 | The TclOO additions of 8.7 and 9.0 (TIP 478, 500, 516, 519, 524, 558, 567) |
| #357 | The msgcat additions of 8.7 (TIP 490, 499) |
| #358 | format and binary scan changes of 9.0 (TIP 586, 697) |
| #359 | The old forms of trace in 9.1 mode (TIP 673) |
| #360 | List indexes above 2^31 (TIP 616, 626) |
| #361 | int() keeps the low 64 bits in 9.1 mode (TIP 514) |
| #362 | auto_execok and the Windows exec changes of 9.1 (TIP 753) |

## Ideas

These TIPs are Draft, Rejected, or Withdrawn. Each one has an idea for ztcl beyond Tcl 9.1. None of them is in ztcl.

- [TIP 672](https://core.tcl-lang.org/tips/doc/trunk/tip/672.md): `$((expr))` substitution. A short form for `[expr {...}]` (Voting).
- [TIP 768](https://core.tcl-lang.org/tips/doc/trunk/tip/768.md): `[( ... )]` expression substitution, with lists and tuple assignment from TIP 770 and 772.
- [TIP 457](https://core.tcl-lang.org/tips/doc/trunk/tip/457.md): Named arguments for `proc`. TIP 479 has a variant with a dict of arguments.
- [TIP 480](https://core.tcl-lang.org/tips/doc/trunk/tip/480.md): Type and alias assertions. A type of an argument can give the JIT a fast path.
- [TIP 550](https://core.tcl-lang.org/tips/doc/trunk/tip/550.md): Garbage collection of TclOO objects. ztcl has a collector of its own in `src/gc.zig`.
- [TIP 192](https://core.tcl-lang.org/tips/doc/trunk/tip/192.md): Lazy lists. A list from a generator, for large `lseq` ranges and streams.
- [TIP 420](https://core.tcl-lang.org/tips/doc/trunk/tip/420.md): `vexpr`, a vector expression command. TIP 363 has vector math in the core.
- [TIP 409](https://core.tcl-lang.org/tips/doc/trunk/tip/409.md): UDP sockets in the core.
- [TIP 384](https://core.tcl-lang.org/tips/doc/trunk/tip/384.md): File alteration monitoring: an event when a file changes.
- [TIP 390](https://core.tcl-lang.org/tips/doc/trunk/tip/390.md): A logging API with levels and handlers.
- [TIP 302](https://core.tcl-lang.org/tips/doc/trunk/tip/302.md): `after` on a monotonic clock, so that a change of the system clock has no effect on timers.
- [TIP 374](https://core.tcl-lang.org/tips/doc/trunk/tip/374.md): A `vwait` that does not nest the C stack, so that two waits can end in any order.
- [TIP 411](https://core.tcl-lang.org/tips/doc/trunk/tip/411.md): `chan info`, introspection of a channel and its stack.
- [TIP 669](https://core.tcl-lang.org/tips/doc/trunk/tip/669.md): The process IDs of a command pipeline as a channel property.
- [TIP 703](https://core.tcl-lang.org/tips/doc/trunk/tip/703.md): `info locale` and `info timezone`.
- [TIP 178](https://core.tcl-lang.org/tips/doc/trunk/tip/178.md): `info pid` and `info tid`.
- [TIP 756](https://core.tcl-lang.org/tips/doc/trunk/tip/756.md): Grapheme clusters in string commands.
- [TIP 418](https://core.tcl-lang.org/tips/doc/trunk/tip/418.md): `binary` subcommands that change a byte array in place. TIP 450 is a variant.
- [TIP 676](https://core.tcl-lang.org/tips/doc/trunk/tip/676.md): An `=` command as a short form of `expr` (Rejected).
- [TIP 288](https://core.tcl-lang.org/tips/doc/trunk/tip/288.md): `args` at any position in the formal arguments of a proc (Rejected).
