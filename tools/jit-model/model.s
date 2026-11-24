# Hand-written models of tier 2 loops, in the form that the rules of
# "Tier 2" in docs/jit.md give. Each function runs `n` passes of one loop.
# rdi: a state block (see model.c), rsi: n.
#
# Registers: r12 the state block (in place of the interpreter and the
# frame), r8 to r11 and rdx the values of slots. rax and rcx are scratch.
# Each pass has the joined step check of its part, the guards, and the
# overflow checks. An exit is a return of -1.
# SPDX-License-Identifier: BSD-2-Clause
        .intel_syntax noprefix
        .text
        .set STEP, 0        # the step limit
        .set INCR, 8        # the step of `incr`, read at the entry
        .set ITEMS, 16      # the list buffer: 24-byte Values
        .set LEN, 24        # the list length
        .set USED, 32       # `used` of the list object
        .set CAP, 40        # the buffer length
        .set CELL, 48       # the cell of a slot that stays in memory
        .set HALF, 56       # the double 0.5

# sum.tcl: for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $i}] }
# i: r8, s: r9, n: r10. A part of 4 steps.
        .globl model_sum
model_sum:
        push r12
        mov r12, rdi
        xor r8d, r8d
        xor r9d, r9d
        mov r10, rsi
        mov rdx, [r12 + INCR]
1:      cmp qword ptr [r12 + STEP], 4
        jb 9f
        sub qword ptr [r12 + STEP], 4
        cmp r8, r10
        jge 8f
        mov rax, r9
        add rax, r8
        jo 9f
        mov r9, rax
        mov rax, r8
        add rax, rdx
        jo 9f
        mov r8, rax
        jmp 1b
8:      mov rax, r9
        pop r12
        ret
9:      mov rax, -1
        pop r12
        ret

# nested.tcl, the inner loop: lappend row [expr {$i * $j}] with the
# inline lappend of tier 1 on the cell of `row`. j: r8, i: r9, m: r10.
        .globl model_nested
model_nested:
        push r12
        mov r12, rdi
        xor r8d, r8d
        mov r9, 7
        mov r10, rsi
        mov rdx, [r12 + INCR]
1:      cmp qword ptr [r12 + STEP], 4
        jb 9f
        sub qword ptr [r12 + STEP], 4
        cmp r8, r10
        jge 8f
        mov rax, r9
        imul rax, r8
        jo 9f
        # lappend: the cell holds a list with room at its end.
        mov r11, [r12 + LEN]
        cmp r11, [r12 + USED]
        jne 9f
        cmp r11, [r12 + CAP]
        jae 9f
        lea rcx, [r11 + r11*2]
        mov r11, [r12 + ITEMS]
        mov [r11 + rcx*8], rax
        mov byte ptr [r11 + rcx*8 + 16], 1
        inc qword ptr [r12 + USED]
        inc qword ptr [r12 + LEN]
        mov rax, r8
        add rax, rdx
        jo 9f
        mov r8, rax
        jmp 1b
8:      mov rax, [r12 + LEN]
        pop r12
        ret
9:      mov rax, -1
        pop r12
        ret

# foreach.tcl: foreach x $l { incr s $x }. The item gets a guard of its
# tag. index: r8, s: r9, x: r10, length: r11.
        .globl model_foreach
model_foreach:
        push r12
        mov r12, rdi
        xor r8d, r8d
        xor r9d, r9d
        mov r11, [r12 + LEN]
1:      cmp r8, r11
        jae 8f
        cmp qword ptr [r12 + STEP], 2
        jb 9f
        sub qword ptr [r12 + STEP], 2
        lea rcx, [r8 + r8*2]
        mov rax, [r12 + ITEMS]
        cmp byte ptr [rax + rcx*8 + 16], 1
        jne 9f
        mov r10, [rax + rcx*8]
        add r8, 1
        mov rax, r9
        add rax, r10
        jo 9f
        mov r9, rax
        jmp 1b
8:      mov rax, r9
        pop r12
        ret
9:      mov rax, -1
        pop r12
        ret

# A loop of doubles: set s [expr {$s + $x * 0.5}], with i as the
# counter. i: r8, n: r10, s: xmm0, x: xmm1, 0.5: xmm2.
        .globl model_dsum
model_dsum:
        push r12
        mov r12, rdi
        xor r8d, r8d
        mov r10, rsi
        mov rdx, [r12 + INCR]
        xorpd xmm0, xmm0
        movsd xmm1, qword ptr [r12 + HALF]
        movsd xmm2, qword ptr [r12 + HALF]
1:      cmp qword ptr [r12 + STEP], 4
        jb 9f
        sub qword ptr [r12 + STEP], 4
        cmp r8, r10
        jge 8f
        movapd xmm4, xmm1
        mulsd xmm4, xmm2
        addsd xmm4, xmm0
        movapd xmm0, xmm4
        mov rax, r8
        add rax, rdx
        jo 9f
        mov r8, rax
        jmp 1b
8:      cvttsd2si rax, xmm0
        pop r12
        ret
9:      mov rax, -1
        pop r12
        ret
        .section .note.GNU-stack,"",@progbits
