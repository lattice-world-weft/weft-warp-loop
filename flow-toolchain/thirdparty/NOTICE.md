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
