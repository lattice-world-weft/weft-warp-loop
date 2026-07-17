# Provenance

`actorcompiler/` in this directory is vendored, unmodified (only renamed as
a package: `flow.actorcompiler_py` upstream -> `actorcompiler` here), from:

- Source: https://github.com/apple/foundationdb
- Path: `flow/actorcompiler_py/`
- Commit: `6fafd8e08ee1410917ea6e0d99bd27233c89fe15` (`main`, 2026-07-17)
- License: Apache License, Version 2.0 (the whole FoundationDB project is
  Apache-2.0 licensed; these particular files carry no individual header,
  which is normal for files governed by the repo-wide LICENSE)

This is the **official upstream Python port of the Flow actor compiler**
(`"Python port of the Flow actor compiler"`, per its own `__main__.py`
docstring) - per `cmake/CompileActorCompiler.cmake`, it is FoundationDB's
own **current default** actor-compiler implementation
(`ACTORCOMPILER_COMMAND` = `python -m flow.actorcompiler_py`); the C#/.NET
implementation (`flow/actorcompiler/`) is the legacy fallback path,
enabled only when `FDB_USE_CSHARP_TOOLS` is set. We use the Python
version deliberately, not the C# one: it has **zero external
dependencies** (stdlib only - `hashlib`, `io`, `dataclasses`, `typing`,
`re`, `abc`), and this project already needs Python3 for the next
increment's `ProtocolVersion.h` codegen (Jinja2-templated), so this keeps
the whole toolchain to one language instead of two.

An earlier revision of this PR vendored the C# implementation instead,
with a `dotnet`-based build (self-contained publish per platform). That
was reverted in favor of this Python version once the upstream default
was discovered - see git history on this branch for that prior attempt.

## `flow/` and `contrib/{crc32,stacktrace,folly_memcpy,SimpleOpt,libb64}`

Vendored, unmodified except for the two file-count/exclusion decisions
below, from the same source/commit as above:

- Source: https://github.com/apple/foundationdb
- Paths: `flow/`, `contrib/crc32/`, `contrib/stacktrace/`,
  `contrib/folly_memcpy/`, `contrib/SimpleOpt/`, `contrib/libb64/`
- Commit: `6fafd8e08ee1410917ea6e0d99bd27233c89fe15` (`main`, 2026-07-17)
- License: Apache License, Version 2.0

Per upstream `flow/CMakeLists.txt`, the entire `flow/` directory compiles
as a single library — there is no official networking/non-networking
split — so this is vendored as the whole faithful configuration rather
than a hand-picked subset (per Gall's Law: evolve the configuration that
actually works upstream, don't invent an unproven new one).

**Excluded** (files with their own `main()`, not needed for a library):
`LinkTest.cpp`, `TLSTest.cpp`, `MkCertCli.cpp`, `acac.cpp`, `FlowTest.cpp`,
`CoroTests.cpp`, `IThreadPoolTest.cpp`, `UnitTestRunner.cpp`. Also excluded:
`swift_concurrency_hooks.cpp`, `swift_task_priority.cpp` (the `.cpp`
implementation files needing an actual Swift compiler are not needed since
this project never defines `WITH_SWIFT`).

**Partially kept, one level deeper than first attempted:** `Net2.cpp`
unconditionally `#include`s `flow/swift_concurrency_hooks.h` (not gated by
`WITH_SWIFT` at the `#include` level, only its *contents* are), which
unconditionally needs `swift.h` and `flow/swift/ABI/{Task,MetadataValues}.h`
+ `flow/swift/Basic/FlagSet.h` — small (20 KB, 3 files), self-contained
(stdlib only), plain C++ headers from the swift.org project itself
(Apache License v2.0 with Runtime Library Exception), no Swift compiler
needed to parse them. These are kept. **Not kept:**
`swift_future_support.h`, `swift_stream_support.h`, `unsafe_swift_compat.h`
— these need `SwiftModules/Flow_CheckedContinuation.h`, a file *generated
at build time by running the actual Swift compiler* over a Swift module
(`flow/CMakeLists.txt` line ~269) — a real Swift-toolchain dependency this
project doesn't want. Confirmed nothing in this project's actually-compiled
sources needs them.

Dependency versions, per the real upstream `cmake/CompileBoost.cmake` and
`cmake/GetFmt.cmake`: **Boost 1.86.0** (components: `context` [non-Windows
only] `filesystem iostreams program_options serialization system url`),
**fmt 11.1.4**, plus **OpenSSL** and **Python3 + Jinja2** (for
`ProtocolVersion.h` codegen, `flow/protocolversion/protocol_version.py`).
This project's `vcpkg.json` pulls current vcpkg versions of these, which
may drift slightly from the exact upstream pins — not byte-identical to
FoundationDB's own CI, a deliberate looser match accepted for this
extraction.

Nothing else from FoundationDB is used, copied, or derived here.
