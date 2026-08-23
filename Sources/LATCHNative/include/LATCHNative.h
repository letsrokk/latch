#ifndef LATCH_NATIVE_H
#define LATCH_NATIVE_H

#include <sys/stat.h>

int latch_stat_path(const char *path, struct stat *result);
int latch_lstat_path(const char *path, struct stat *result);
int latch_tcp_check(const char *host, unsigned short port, int timeout_milliseconds);

#endif
