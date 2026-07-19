# s7's actual libc surface, for the RISC-V guest build

Scoped by reading `s7.c` directly (not by assumption), for ADR 0006's
"no musl, no newlib, hand-build only what s7 needs" constraint. `s7.c`
is `#include "mus-config.h"` unconditionally, and s7's own embedding
docs (`s7.html`, the minimal-repl recipe) confirm this file can be
empty. Several OS-facing includes are gated behind config macros that
default to off when `mus-config.h` is empty, so they need nothing:

- `dlfcn.h` — behind `WITH_C_LOADER` (default unset/0): C module dynamic
  loading. Irrelevant for a sandboxed guest with no filesystem anyway.
- `fcntl.h`, `dirent.h` — behind `WITH_SYSTEM_EXTRAS` (default
  unset/0): file descriptors, directory listing.
- `signal.h` — behind `TRAP_SEGFAULT` (default unset/0): segv->longjmp
  guard around `s7_is_valid`.
- `sys/stat.h` — included unconditionally on non-Windows for
  `is_directory()`, but the function's body is gated on `S_ISDIR` being
  defined; if it isn't, `is_directory()` always returns `false`.
  Defining `MS_WINDOWS=1` at compile time skips the include and the
  `S_ISDIR` branch entirely, unconditionally returning `false` — correct
  for a guest with no real filesystem, and removes this header from the
  required set without needing to implement `stat()`/`S_ISDIR` at all.
- `WITH_GMP` already defaults to 0 in `s7.c` itself (no bignum/GMP
  dependency to worry about).

What's left, unconditionally required (`s7.c:300-335`):

- `limits.h`, `stddef.h`, `stdarg.h` — pure compile-time constants/macros,
  no runtime implementation needed beyond what the compiler ships.
- `ctype.h` — `isdigit`/`isspace`/`isalpha`/etc. character classification.
- `string.h` — `strlen`, `strcmp`, `strcpy`/`strncpy`, `memcpy`, `memmove`,
  `memset`, `strchr`, `strstr`, and similar.
- `stdlib.h` — `malloc`/`free`/`realloc`, `strtod`/`strtol`, `qsort`,
  `abs`.
- `sys/types.h` — typedefs only (`size_t` etc., mostly already covered
  by `stddef.h`).
- `time.h` — s7 has a `(current-time)`-style feature; needs a
  `time()`/`clock()` shim. Worth checking whether this is itself gated
  behind a feature macro before committing to implementing real wall-clock
  syscalls in the guest (a sandboxed guest reading real time is itself a
  determinism question ADR 0006 hasn't settled — likely wants a
  host-supplied deterministic tick instead of a raw clock syscall).
- `setjmp.h` — s7's error/continuation handling uses this directly (not
  gated); needs `setjmp`/`longjmp`, which are usually compiler
  intrinsics/builtins rather than real libc calls, so likely free.
- `math.h` (linked as `-lm` upstream, no `#include <math.h>` line found
  directly — reached via implicit declarations/macros) — confirmed used:
  `acos asin atan atan2 cbrt ceil cos cosh exp fabs floor fmod hypot
  isinf log log2 pow round sin sinh sqrt tan tanh`. This is the bulk of
  the implementation work: either hand-write these (well-understood,
  freely available reference algorithms exist for most, e.g. from
  `fdlibm`-style public-domain implementations) or find a
  permissively-licensed, dependency-free single-file libm to vendor
  instead of writing 20+ transcendental functions from scratch — still
  consistent with "no musl/newlib" since libm is a much narrower,
  separable piece than a whole libc.

## Next step

Confirm the `time.h` question (what s7 actually calls it for, and
whether a deterministic host-supplied tick can stand in for it), then
start the hand-built libc subset: `string.h`/`stdlib.h`/`ctype.h`
implementations are small and mechanical; `setjmp.h` is likely free via
compiler builtins; `math.h` is the real work and needs its own sourcing
decision before writing code.
