# Provenance

`picoquic/`, `picotls/`, `mbedtls/` are vendored, unmodified, from
https://github.com/fire/webtransportd, path
`thirdparty/{picoquic,picotls,mbedtls}`, commit
`b53faa2d1b94b2d3e3ee7f1591c82d0a7ea2952e` (`main`):

- `picoquic`: MIT
- `picotls`: MIT
- `mbedtls`: Apache License 2.0

(see each subtree's own `LICENSE`/`README.md`)

The file selection mirrors `webtransportd`'s own already-proven
`CMakeLists.txt` `vendored` target. One difference: `picoquic`'s own
socket-loop files (`sockloop.c`, `winsockloop.c`) are excluded on every
platform here, not just Windows — see the README's "Architecture"
section for why (`webtransportd` wants picoquic managing real sockets;
this project doesn't).

`libriscv/` is vendored, unmodified, via `git subtree`, from
https://github.com/libriscv/libriscv, tag `v1.18`: BSD 3-Clause License
(see `libriscv/LICENSE`). Host-side library only —
`docs/decisions/0006-libriscv-sandboxed-s7-lisp-over-native-janet.md`
records the RISC-V sandbox this repository builds toward; the guest
language (s7) is vendored, but not yet cross-compiled to run inside it.

`s7/` is vendored, unmodified, via `git subtree`, from
https://github.com/Conservatory/s7 (an unofficial but actively-updated
mirror of Bill Schottstaedt's CCRMA `s7`; upstream ships no GitHub
releases/tags to pin to), commit `84c9c62bf4c0e3f5c605975f43492387ca3bf78b`
(`master`). No separate `LICENSE` file ships upstream; the license notice
lives in `s7/s7.c`'s header comment — a permissive BSD-style grant
("permission to use, copy, modify, distribute, and license this software
... for any purpose. No written agreement, license, or royalty fee is
required"). This is ADR 0006's chosen guest Lisp-1; nothing yet
cross-compiles it to RISC-V or wires it into libriscv.
