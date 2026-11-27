// SPDX-License-Identifier: BSD-2-Clause
// A WASI program for the tests of ztcl::wasm: arguments, environment,
// standard output and error, the exit code, and some arithmetic.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned long fib(unsigned n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int main(int argc, char **argv) {
    printf("argc %d\n", argc);
    for (int i = 1; i < argc; i++) printf("arg %d %s\n", i, argv[i]);
    const char *who = getenv("WHO");
    printf("who %s\n", who ? who : "(none)");
    printf("fib 20 %lu\n", fib(20));
    double x = 0;
    for (int i = 1; i <= 1000; i++) x += 1.0 / ((double)i * i);
    printf("sum %.6f\n", x);
    char *buf = malloc(1 << 20);
    memset(buf, 'z', 1 << 20);
    printf("malloc %c\n", buf[(1 << 20) - 1]);
    free(buf);
    fprintf(stderr, "to stderr\n");
    char line[100];
    if (fgets(line, sizeof line, stdin)) printf("stdin %s", line);
    return argc > 3 ? 7 : 0;
}
