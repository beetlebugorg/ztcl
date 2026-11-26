# Writes src/cext/slots.zig: the slots of the four stubs tables of Tcl 8.6
# and the area of each public slot. The layout comes from the C
# preprocessor on the Tcl 8.6 headers, so the slot numbers are the
# numbers of the Unix build. Only the slot numbers and the field names go
# into the output.
#   python3 -I stubs.py TCL_SRC > src/cext/slots.zig
# SPDX-License-Identifier: BSD-2-Clause
import re, subprocess, sys, tempfile, os
tcl = sys.argv[1]
d = tempfile.mkdtemp()
open(d + '/h.c', 'w').write('#include <tclInt.h>\n#include <tclIntPlatDecls.h>\n#include <tclPlatDecls.h>\n')
s = subprocess.run(['cc', '-E', '-P', '-DHAVE_UNISTD_H', '-DHAVE_SYS_PARAM_H', '-DHAVE_STDINT_H',
    '-DHAVE_INTTYPES_H', '-DHAVE_LIMITS_H', '-DHAVE_STDLIB_H', '-DHAVE_STRING_H',
    '-I' + tcl + '/generic', '-I' + tcl + '/unix', d + '/h.c'], check=True, capture_output=True, text=True).stdout

def fields(t):
    body = re.search(r'typedef struct ' + t + r' \{(.*?)\} ' + t + ';', s, re.S).group(1)
    out = []
    for x in [x for x in body.split(';') if x.strip()][2:]:
        m = re.search(r'\(\*\s*(\w+)\)', x)
        n = m.group(1)
        out.append(None if n.startswith('reserved') else n[0].upper() + n[1:])
    return out

# The first rule that matches the name without its "Tcl_" prefix gives
# the area. The order of the rules matters.
rules = [
    ('memory', r'(Attempt)?(Alloc|Free|Realloc)|(Attempt)?DbCk\w+|DumpActiveMemory|ValidateAllMemory|InitMemory|Preserve|Release|EventuallyFree'),
    ('threads', r'Mutex\w+|Condition\w+|CreateThread|JoinThread|ExitThread|FinalizeThread|GetCurrentThread|GetThreadData|\w*ThreadExitHandler|GetAllocMutex'),
    ('errors', r'Panic(VA)?|SetPanicProc|Add(Obj)?ErrorInfo|AppendObjToErrorInfo|Set(Obj)?ErrorCode(VA)?|Background(Error|Exception)|PosixError|Errno(Id|Msg)|[GS]etErrno|Signal(Id|Msg)|LogCommandInfo|[GS]etErrorLine|[GS]etReturnOptions|WrongNumArgs|AllowExceptions'),
    ('lists and dicts', r'ListObj\w+|(Db)?New(List|Dict)Obj|SetListObj|DictObj\w+|SplitList|Merge|Scan(Counted)?Element|Convert(Counted)?Element|Concat(Obj)?'),
    ('zlib', r'Zlib\w+'),
    ('events', r'(Create|Delete)FileHandler|SetTimer|Sleep|WaitForEvent|\w*TimerHandler|DoWhenIdle|CancelIdleCall|\w*EventSource|QueueEvent|ServiceEvent|ServiceAll|DeleteEvents|DoOneEvent|SetMaxBlockTime|\w*ServiceMode\w*|\w*Notifier|ThreadQueueEvent|ThreadAlert|SetMainLoop|GetTime|SetTimeProc|QueryTimeProc|Async\w+'),
    ('channels', r'\w*Channel\w*|Close(Ex)?|Eof|Flush|Gets(Obj)?|Read(Raw|Chars)?|Write(Raw|Chars|Obj)?|Ungets|Seek(Old)?|Tell(Old)?|Input(Blocked|Buffered)|OutputBuffered|GetOpenFile|OpenTcp\w+|CreatePipe|DetachPids|ReapDetachedProcs|WaitPid|(Create|Delete)CloseHandler'),
    ('filesystem', r'FS\w+|Get\w+FromStat|AllocStatBuf|Access|Stat|GetCwd|Chdir|JoinPath|SplitPath|GetPathType|TranslateFileName'),
    ('strings and encodings', r'Utf\w+|UniChar\w+|NumUtfChars|\w*Encoding\w*|ExternalToUtf\w*|(New|Set)UnicodeObj|GetCharLength|GetUniChar|GetUnicode\w*|GetRange|AppendUnicodeToObj|String(Case)?Match|Backslash|DString\w+|Format|AppendFormatToObj|ObjPrintf|AppendPrintfToObj|AppendLimitedToObj|PrintDouble|RegExp\w+|GetRegExpFromObj'),
    ('namespaces', r'\w*Namespace\w*|AppendExportList|Export|Import|ForgetImport|\w*Ensemble\w*'),
    ('packages', r'Pkg\w+|StaticPackage|GetVersion|RegisterConfig|LoadFile|FindSymbol|FindExecutable|GetNameOfExecutable|SourceRCFile|[SG]etStartupScript|Init'),
    ('scripts and results', r'Eval\w*|GlobalEval\w*|VarEval\w*|RecordAndEval\w*|Expr\w*|SubstObj|NR\w+|Parse\w+|EvalTokens\w*|FreeParse|CommandComplete|\w*Result\w*|AppendElement|(Save|Restore|Discard)InterpState|CancelEval|Canceled'),
    ('variables', r'\w*Var\w*'),
    ('hash tables', r'\w*HashTable|\w*HashEntry|HashStats|\w*AssocData'),
    ('interps and commands', r'Create(Alias|Obj)\w*|GetAliasObj|ProcObjCmd|CreateObjTrace|GetCommandFromObj'),
    ('objects', r'\w*Obj\w*|GetBoolean|GetDouble|GetInt|InvalidateStringRep|GetString|AppendAllObjTypes|ConvertToType|Db(Decr|Incr)RefCount|DbIsShared|FreeObj|\w*Bignum\w*|AppendToObj|AppendStringsToObj(VA)?|SetByteArrayLength'),
    ('interps and commands', r'\w+'),
]
areas = list(dict.fromkeys(r[0] for r in rules))
def area(n):
    b = re.sub(r'^Tcl_?', '', n)
    for a, r in rules:
        if re.fullmatch(r, b): return a
pub = fields('TclStubs')
print('//! The slots of the four stubs tables of Tcl 8.6, from the Unix headers.')
print('//! `tools/cext/stubs.py` writes this file. A null slot is reserved.')
print('//! Each public slot has the area of its group of the build-out.')
print('//!')
print('//! SPDX-License-Identifier: BSD-2-Clause')
print()
print('pub const Area = enum {')
for a in areas: print(f'    {a.replace(" ", "_")},')
print()
print('    pub fn label(a: Area) []const u8 {')
print('        return switch (a) {')
for a in areas: print(f'            .{a.replace(" ", "_")} => "{a}",')
print('        };')
print('    }')
print('};')
print()
print('pub const Slot = struct { name: []const u8, area: Area };')
print()
print('pub const public = [_]?Slot{')
for n in pub:
    print('    null,' if n is None else f'    .{{ .name = "{n}", .area = .{area(n).replace(" ", "_")} }},')
print('};')
for t, k in [('TclIntStubs', 'internal'), ('TclPlatStubs', 'plat'), ('TclIntPlatStubs', 'int_plat')]:
    print()
    fs = fields(t)
    if not fs:
        print(f'pub const {k} = [_]?[]const u8{{}};')
        continue
    print(f'pub const {k} = [_]?[]const u8{{')
    for n in fs: print('    null,' if n is None else f'    "{n}",')
    print('};')
