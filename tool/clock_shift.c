// Shifts the wall clock for a time-dependence audit of the test suite
// (see tool/test_on_another_day.sh). Only CLOCK_REALTIME, gettimeofday and
// time are shifted; monotonic clocks, sleeps and thread primitives are left
// alone, because libfaketime, which fakes those too, hangs the Dart VM.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>

static long shift_seconds(void) {
  static long value = 0;
  static int ready = 0;
  if (!ready) {
    const char *s = getenv("CLOCK_SHIFT_DAYS");
    value = s ? atol(s) * 86400L : 0;
    ready = 1;
  }
  return value;
}

int clock_gettime(clockid_t id, struct timespec *ts) {
  static int (*real)(clockid_t, struct timespec *) = 0;
  if (!real) real = dlsym(RTLD_NEXT, "clock_gettime");
  int r = real(id, ts);
  if (r == 0 && id == CLOCK_REALTIME) ts->tv_sec += shift_seconds();
  return r;
}

int gettimeofday(struct timeval *tv, void *tz) {
  static int (*real)(struct timeval *, void *) = 0;
  if (!real) real = dlsym(RTLD_NEXT, "gettimeofday");
  int r = real(tv, tz);
  if (r == 0 && tv) tv->tv_sec += shift_seconds();
  return r;
}

time_t time(time_t *out) {
  static time_t (*real)(time_t *) = 0;
  if (!real) real = dlsym(RTLD_NEXT, "time");
  time_t t = real(0) + shift_seconds();
  if (out) *out = t;
  return t;
}
