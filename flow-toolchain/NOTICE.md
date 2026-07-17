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

Nothing else from FoundationDB is used, copied, or derived here.
