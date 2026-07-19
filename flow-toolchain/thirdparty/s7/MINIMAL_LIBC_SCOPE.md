# s7's actual libc surface, for the RISC-V guest build

Scoped by reading `s7.c` directly (not by assumption), for ADR 0006's
"no musl, no newlib, hand-build only what s7 needs" constraint. `s7.c`
is `#include "mus-config.h"` unconditionally, and s7's own embedding
docs (`s7.html`, the minimal-repl recipe) confirm this file can be
empty. Several OS-facing includes are gated behind config macros that
default to off when `mus-config.h` is empty, so they need nothing:

- `dlfcn.h` — behind `WITH_C_LOADER`. Correction from an earlier pass of
  this doc: `WITH_C_LOADER` does **not** default to 0 with an empty
  `mus-config.h` — `s7.c:221` defines it as `WITH_GCC`, which is itself
  `(defined(__GNUC__) || defined(__clang__))` (`s7.c:244`), i.e. true on
  any GCC/Clang build unless explicitly overridden. Confirmed the hard
  way: a native build with an empty `mus-config.h` on this host still
  tried to `#include <dlfcn.h>` and failed. The RISC-V guest build must
  pass `-DWITH_C_LOADER=0` explicitly — an empty `mus-config.h` alone is
  not enough. Irrelevant for a sandboxed guest with no filesystem anyway.
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
- `time.h` — resolved. Exactly two real call sites in all of `s7.c`:
  `clock()` once (backs the `cpu-time` introspection accessor,
  `s7.c:73172`), and `time(NULL)` once in the non-GMP branch (seeds the
  default RNG state, `s7.c:75024`; the GMP-branch sibling call is dead
  code here since `WITH_GMP` defaults to 0). Neither needs a real
  wall-clock syscall: `clock()` can return a monotonic counter derived
  from the guest's own instruction count (which libriscv already tracks
  and which is deterministic per ADR 0006's whole premise — arguably more
  correct than a real wall-clock value would be, since Flow's replay
  contract explicitly excludes real time as an input), and the RNG seed
  should come from a host-supplied deterministic seed (passed in at
  guest-call time, the same way any other simulation input would be) 
  rather than `time(NULL)`, which would make script RNG non-reproducible
  across peers — the opposite of what this ADR needs. So: no real
  `time.h` implementation needed, just two small shims wired to
  host-controlled values instead of OS time.
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
