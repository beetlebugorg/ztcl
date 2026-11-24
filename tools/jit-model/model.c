/* The driver of the models of model.s: `model NAME N` runs one model
 * with N passes and prints its result.
 * SPDX-License-Identifier: BSD-2-Clause */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct value { long long payload; long long len; unsigned char tag; char pad[7]; };
struct state {
    unsigned long long step; long long incr; struct value *items;
    unsigned long long len, used, cap; long long cell; double half;
};

long long model_sum(struct state *, long long);
long long model_nested(struct state *, long long);
long long model_foreach(struct state *, long long);
long long model_dsum(struct state *, long long);

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    long long n = atoll(argv[2]);
    struct state s = { .step = ~0ull, .incr = 1, .half = 0.5 };
    s.cap = n + 1;
    s.items = calloc(s.cap, sizeof(struct value));
    long long r;
    if (!strcmp(argv[1], "sum")) r = model_sum(&s, n);
    else if (!strcmp(argv[1], "nested")) r = model_nested(&s, n);
    else if (!strcmp(argv[1], "foreach")) {
        for (long long k = 0; k < n; k++) { s.items[k].payload = k; s.items[k].tag = 1; }
        s.len = s.used = n;
        r = model_foreach(&s, n);
    } else if (!strcmp(argv[1], "dsum")) r = model_dsum(&s, n);
    else return 2;
    printf("%lld\n", r);
    return 0;
}
