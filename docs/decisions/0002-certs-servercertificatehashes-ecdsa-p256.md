# Short-lived self-signed ECDSA-P256 certs via serverCertificateHashes

## Status

Accepted (part of planned PR 2; not yet implemented).

## Decision

Browser WebTransport requires TLS the browser trusts, but demo/LAN
deployments have no CA-issued certificate, and the vendored TLS stack
(picotls minicrypto/mbedtls, no OpenSSL backend) can't produce the
RSA-PSS CertificateVerify TLS 1.3 requires for RSA certs. W3C
WebTransport's `serverCertificateHashes` lets a client pin a SHA-256
hash instead of chaining to a CA, for certificates that are ECDSA and
valid ≤14 days — which the vendored stack already signs fine (CI already
uses picoquic's secp256r1 test certs for this reason). Mint a ≤14-day
self-signed ECDSA-P256 cert and print its SHA-256 hash at startup,
patterned on webtransportd's `adapters/autocert.c`; the browser or Godot
`WebTransportPeer` passes that hash to `new WebTransport(url,
{serverCertificateHashes})`. CA-issued certificates stay open for real
deployments but aren't a demo requirement; a long-lived self-signed cert
doesn't work at all — browsers offer no WebTransport trust bypass.

## Consequences

Good: zero-infrastructure demos on localhost and LANs. Bad: certs expire
in ≤14 days by spec, so the mint script must run routinely (or at server
start); hash distribution is out-of-band — fine for demos, not a
production trust model.
