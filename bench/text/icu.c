// Counts the grapheme clusters, words, and sentences of a UTF-8 file
// with the break iterators of an installed ICU, for the comparison in
// bench/text/run.sh. It converts the text to UTF-16 before the clock
// starts, since UTF-16 is the native form of ICU.
//
//   cc -O2 bench/text/icu.c -o icu-bench $(pkg-config --cflags --libs icu-uc)
//   ./icu-bench FILE ROUNDS
//
// SPDX-License-Identifier: BSD-2-Clause
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unicode/ubrk.h>
#include <unicode/ustring.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 1;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(n);
    if (fread(buf, 1, n, f) != (size_t)n) return 1;
    fclose(f);
    UErrorCode e = U_ZERO_ERROR;
    int32_t len = 0;
    u_strFromUTF8(NULL, 0, &len, buf, n, &e);
    e = U_ZERO_ERROR;
    UChar *u = malloc(sizeof(UChar) * (len + 1));
    u_strFromUTF8(u, len + 1, &len, buf, n, &e);
    if (U_FAILURE(e)) return 1;
    int rounds = atoi(argv[2]);
    const UBreakIteratorType kinds[3] = {UBRK_CHARACTER, UBRK_WORD, UBRK_SENTENCE};
    const char *names[3] = {"graphemes", "words", "sentences"};
    for (int k = 0; k < 3; k++) {
        double best = 1e9;
        long count = 0;
        for (int r = 0; r < rounds; r++) {
            e = U_ZERO_ERROR;
            UBreakIterator *bi = ubrk_open(kinds[k], "en", u, len, &e);
            if (U_FAILURE(e)) return 1;
            double t0 = now();
            count = 0;
            for (int32_t p = ubrk_first(bi); p != UBRK_DONE; p = ubrk_next(bi)) count++;
            double t = now() - t0;
            ubrk_close(bi);
            if (t < best) best = t;
        }
        printf("icu\t%s\t%ld\t%.1f\n", names[k], count - 1, n / best / 1e6);
    }
    return 0;
}
