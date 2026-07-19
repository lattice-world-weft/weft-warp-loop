# Native s7 devtool agent (ADR 0006 item 10)

`s7agent_main.c` + `s7_h3_ffi.c` + `artifacts-mmo-agent.scm` is a
working, tested instance of the native-host s7 devtool tier ADR 0006
records: s7 built for the local machine, against the ordinary system
libc — not the freestanding RISC-V guest tier, which has no I/O by
design and is the wrong place for anything network-facing like this.

`taskweft-lite.scm` (this same directory) proves the HTN-planning style
against this repo's own offline `plan/bootstrap-domain.json`, with
methods as fixed data (subtask lists) — fine there, since that domain has
one static answer. `artifacts-mmo-agent.scm` extends the same style to a
live external API (ArtifactsMMO) using taskweft's actual RECTGTN
discipline instead (`taskweft/taskweft`'s `docs/rectgtn.md`, the model
behind the `mcp__taskweft__plan`/`replan` tools): a todo-list of goals,
each decomposed lazily against *current* state — where the nearest
tile for a resource is isn't knowable ahead of time, it's a live map
query — with a real replan-on-failure loop (a cooldown-still-active
error retries the same action after waiting; anything else re-decomposes
the whole goal from fresh state). The decision runs in Scheme; the
actual HTTP call goes through `s7_h3_ffi.c`'s
`(http-request method url bearer-token body)`.

## Transport: this project's own vendored HTTP/3 client, not curl

`s7_h3_ffi.c` shells out to `artifacts_mmo_h3_client` (this same
directory) — the vendored picoquic + picotls + mbedtls stack doing real
authenticated HTTP/3 (custom `authorization` header, GET and POST with a
JSON body). curl is gone from this chain entirely; the only external
process the agent still spawns is this project's own compiled binary.

Direct in-process linking (s7 and picoquic in one binary) was tried
first and hit a real upstream gap: `thirdparty/s7/s7.c`'s
`is_decodable()` is defined only under `#ifndef _MSC_VER` but still
referenced from a call site that isn't excluded the same way, so `s7.c`
fails to link under clang-cl/MSVC specifically. Vendored files stay
unmodified in this repo, so that isn't patched here. The alternative —
building s7 with llvm-mingw (which doesn't define `_MSC_VER`, so doesn't
hit the gap) and linking it against picoquic built under clang-cl in one
binary — would mean two different C runtimes statically linked into one
executable, a real if narrow risk this devtool doesn't need to take on.
A subprocess boundary sidesteps both problems: `s7agent` (s7 + the FFI)
builds entirely with llvm-mingw, `artifacts_mmo_h3_client` (picoquic)
builds entirely with clang-cl, and they never share a runtime.

## Build

`artifacts_mmo_h3_client` (needs clang-cl + the vendored picoquic
sources — see `flow-toolchain/CMakeLists.txt`'s own target for the exact
include paths and compiler flags this requires) must be built first;
`s7agent` is told its path at compile time.

```sh
# s7agent: llvm-mingw (verified on Windows; adjust for other hosts)
touch mus-config.h   # s7's own docs: "make mus-config.h (it can be empty)"
gcc -std=gnu99 -O2 -I. -I../thirdparty/s7 -DWITH_C_LOADER=0 \
    -c ../thirdparty/s7/s7.c -o s7.o
gcc -std=gnu99 -O2 -I. -I../thirdparty/s7 \
    -DARTIFACTS_MMO_H3_CLIENT_EXE="\"/path/to/artifacts_mmo_h3_client.exe\"" \
    -DARTIFACTS_MMO_CACERT_PATH="\"/path/to/certs/mozilla-cacert.pem\"" \
    s7agent_main.c s7_h3_ffi.c s7.o -lm -o s7agent
```

`-DWITH_C_LOADER=0` matters: s7.c defines `WITH_C_LOADER` as
`WITH_GCC` (true for both GCC and Clang) unless told otherwise, which
pulls in `<dlfcn.h>` — unavailable and unneeded here. See
`../thirdparty/s7/MINIMAL_LIBC_SCOPE.md` for the rest of what s7 actually
needs from a libc, scoped for the (separate, unstarted) RISC-V guest
build.

A `cmd.exe` quirk worth knowing if this stops working after an edit:
`popen()`'s command string must be wrapped in one extra pair of quotes
around the whole thing (`""path\to.exe" args"`, not `"path\to.exe" args`)
— cmd.exe's own `/c` parsing mishandles a command that starts with a
quoted path followed by more arguments otherwise, failing with "The
filename, directory name, or volume label syntax is incorrect."

## Run

Requires `ARTIFACTS_MMO_APIKEY` set to a valid ArtifactsMMO bearer token
(read by `artifacts_mmo_h3_client`, inherited by it as a child process —
`s7agent`/`s7_h3_ffi.c` never see the token directly).

```sh
./s7agent artifacts-mmo-agent.scm
```

Proven end to end against the live server, transport included: the
todo-list of four level-1 resources (`ash_tree`, `copper_rocks`,
`sunflower_field`, `gudgeon_spot`), each goal decomposed into a live map
query for the nearest tile, a move (skipped if already there, executed
as a real authenticated POST with a JSON body), and a gather, waiting out
the real per-action cooldown between actions. Confirmed via a fresh
`GET /characters/AriaWeft` afterward: inventory quantities genuinely
increased across all four resources.

## Not done here

- No JSON library is vendored; `json-int-field`/`has-error` in the
  agent script are small purpose-built scanners for the handful of
  fields this domain reads, not a general parser.
- No shrubbery-notation surface syntax — this is plain s7 s-expressions,
  same as `taskweft-lite.scm`. ADR 0006's shrubbery reader is unstarted.
- `remaining_seconds` occasionally fails to parse out of a 499 cooldown
  error response (cosmetic — the retry still proceeds via a hardcoded
  5-second fallback in that case) — not tracked down further yet.
