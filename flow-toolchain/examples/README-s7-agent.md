# Native s7 devtool agent (ADR 0006 item 10)

`s7agent_main.c` + `s7_http_ffi.c` + `artifacts-mmo-agent.scm` is a
working, tested instance of the native-host s7 devtool tier ADR 0006
records: s7 built for the local machine, against the ordinary system
libc — not the freestanding RISC-V guest tier, which has no I/O by
design and is the wrong place for anything network-facing like this.

`taskweft-lite.scm` (this same directory) proves the HTN-planning style
against this repo's own offline `plan/bootstrap-domain.json`.
`artifacts-mmo-agent.scm` extends that same style to a live external API
(ArtifactsMMO): fetch state, decide the next primitive action, execute
it — with the *decision* made in Scheme and the actual HTTP call made
through `s7_http_ffi.c`'s `(http-request method url bearer-token body)`,
not by hand-issued shell commands.

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

Proven end to end against the live server: moves the character to a
known `ash_tree` tile (found via `GET /maps?content_code=ash_tree`) and
gathers it, waiting out the real per-action cooldown
(`agent-sleep`/`remaining_seconds`) between the move and the gather.

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
