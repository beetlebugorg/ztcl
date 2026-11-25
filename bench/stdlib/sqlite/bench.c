// The same SQLite work in the C API: bench ROWS
// Prints "insert SECONDS" and "select SECONDS", the best of 3 runs.
// SPDX-License-Identifier: BSD-2-Clause
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    long rows = atol(argv[1]);
    sqlite3 *db;
    sqlite3_open(":memory:", &db);
    sqlite3_exec(db, "CREATE TABLE t(a INTEGER, b REAL, c TEXT)", 0, 0, 0);
    double bi = 1e9, bs = 1e9;
    for (int k = 0; k < 3; k++) {
        sqlite3_exec(db, "DELETE FROM t", 0, 0, 0);
        double t = now();
        sqlite3_stmt *s;
        sqlite3_exec(db, "BEGIN", 0, 0, 0);
        sqlite3_prepare_v2(db, "INSERT INTO t VALUES(?, ?, 'row')", -1, &s, 0);
        for (long i = 0; i < rows; i++) {
            sqlite3_bind_int64(s, 1, i);
            sqlite3_bind_double(s, 2, i * 0.5);
            sqlite3_step(s);
            sqlite3_reset(s);
        }
        sqlite3_finalize(s);
        sqlite3_exec(db, "COMMIT", 0, 0, 0);
        double d = now() - t;
        if (d < bi) bi = d;
        t = now();
        sqlite3_prepare_v2(db, "SELECT a, b, c FROM t", -1, &s, 0);
        long n = 0;
        while (sqlite3_step(s) == SQLITE_ROW) {
            n += sqlite3_column_int64(s, 0) + (long)sqlite3_column_double(s, 1);
            n += sqlite3_column_bytes(s, 2) + (sqlite3_column_text(s, 2) != 0);
        }
        sqlite3_finalize(s);
        d = now() - t;
        if (d < bs) bs = d;
        if (n == -1) puts("");
    }
    printf("insert %g\nselect %g\n", bi, bs);
    return 0;
}
