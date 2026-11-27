// SPDX-License-Identifier: BSD-2-Clause
// A WASI program for the tests of ztcl::wasm: files in a preopened
// folder, a folder list, and a path that leaves the folder.
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    FILE *f = fopen("out.txt", "w");
    if (!f) { printf("open failed %d\n", errno); return 1; }
    fprintf(f, "line one\nline two\n");
    fclose(f);
    f = fopen("out.txt", "a");
    fprintf(f, "line three\n");
    fclose(f);
    f = fopen("out.txt", "r");
    char line[64];
    int n = 0;
    while (fgets(line, sizeof line, f)) n++;
    fseek(f, 5, SEEK_SET);
    fgets(line, sizeof line, f);
    printf("lines %d, at 5: %s", n, line);
    fclose(f);
    struct stat st;
    stat("out.txt", &st);
    printf("size %lld\n", (long long)st.st_size);
    mkdir("sub", 0777);
    f = fopen("sub/inner.txt", "w");
    fputs("x", f);
    fclose(f);
    rename("sub/inner.txt", "sub/moved.txt");
    DIR *d = opendir("sub");
    struct dirent *e;
    while ((e = readdir(d))) if (e->d_name[0] != '.') printf("entry %s\n", e->d_name);
    closedir(d);
    unlink("sub/moved.txt");
    printf("rmdir %d\n", rmdir("sub"));
    f = fopen("../escape.txt", "w");
    printf("escape %s\n", f ? "opened" : "refused");
    f = fopen("missing.txt", "r");
    printf("missing %s\n", f ? "opened" : strerror(errno));
    return 0;
}
