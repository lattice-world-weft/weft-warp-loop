# Native s7 devtool agent (ADR 0006 item 10)

`s7agent_main.c` + `s7_http_ffi.c` + `artifacts-mmo-agent.scm` is a
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
actual HTTP call goes through `s7_http_ffi.c`'s
`(http-request method url bearer-token body)`, not hand-issued shell
commands.

## Build (verified with llvm-mingw on Windows; adjust the compiler
## invocation for other hosts — nothing else here is Windows-specific)

```sh
touch mus-config.h   # s7's own docs: "make mus-config.h (it can be empty)"
gcc -std=gnu99 -O2 -I. -I../thirdparty/s7 -DWITH_C_LOADER=0 \
    -c ../thirdparty/s7/s7.c -o s7.o
gcc -std=gnu99 -O2 -I. -I../thirdparty/s7 \
    s7agent_main.c s7_http_ffi.c s7.o -lm -o s7agent
```

`-DWITH_C_LOADER=0` matters: s7.c defines `WITH_C_LOADER` as
`WITH_GCC` (true for both GCC and Clang) unless told otherwise, which
pulls in `<dlfcn.h>` — unavailable and unneeded here. See
`../thirdparty/s7/MINIMAL_LIBC_SCOPE.md` for the rest of what s7 actually
needs from a libc, scoped for the (separate, unstarted) RISC-V guest
build.

## Run

Requires `curl` on `PATH` and `ARTIFACTS_MMO_APIKEY` set to a valid
ArtifactsMMO bearer token.

```sh
./s7agent artifacts-mmo-agent.scm
```

Proven end to end against the live server: runs the todo-list of four
level-1 resources (`ash_tree`, `copper_rocks`, `sunflower_field`,
`gudgeon_spot`), each goal decomposed into a live map query for the
nearest tile, a move (skipped if already there), and a gather, waiting
out the real per-action cooldown (`agent-sleep`/`remaining_seconds`)
between actions. All four succeeded on the first attempt in the run
this was verified against — no replans needed, but the retry/replan
path is exercised by any 499 (cooldown) or other action error.

## Not done here

- No JSON library is vendored; `json-int-field`/`has-error` in the
  agent script are small purpose-built scanners for the handful of
  fields this domain reads, not a general parser.
- No shrubbery-notation surface syntax — this is plain s7 s-expressions,
  same as `taskweft-lite.scm`. ADR 0006's shrubbery reader is unstarted.
- The transport is curl, not the vendored picoquic H3 client
  (`picoquicdemo_client`, this same directory's `CMakeLists.txt` entry) —
  that path is proven as an HTTP/3 client against this same live server,
  but authenticated requests need a QPACK header-frame encoder for a
  custom `Authorization` header, which is not yet built (see
  `docs/decisions/0007-s7-shrubbery-toolchain-scope-and-elixir-nif-comparison.md`).
