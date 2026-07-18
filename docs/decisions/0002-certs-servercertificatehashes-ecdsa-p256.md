# Short-lived self-signed ECDSA-P256 certs via serverCertificateHashes

## Status

Accepted (part of planned PR 2; not yet implemented).

## Context and Problem Statement

Browser WebTransport requires TLS the browser trusts. Demo and LAN
deployments have no CA-issued certificate, and the vendored TLS stack
(picotls minicrypto/mbedtls, no OpenSSL backend) cannot produce the
RSA-PSS CertificateVerify that TLS 1.3 requires for RSA certs — RSA
certs fail the handshake with alert 51 (decrypt_error), as documented in
the flow-runtime CI workflow.

## Decision Drivers

- W3C WebTransport allows `serverCertificateHashes`: the client pins a
  SHA-256 hash instead of chaining to a CA, but only for certificates
  that are ECDSA and valid ≤ 14 days.
- The vendored stack signs ECDSA (secp256r1) fine; CI already uses the
  picoquic secp256r1 test certs for exactly this reason.
- Demos must work with zero DNS/CA setup.

## Considered Options

1. Script that mints a ≤14-day self-signed ECDSA-P256 cert and emits its
   SHA-256 hash for `serverCertificateHashes`.
2. CA-issued certificates (Let's Encrypt et al.).
3. Ship a long-lived self-signed cert and ask users to bypass trust.

## Decision Outcome

Chosen option 1, patterned on webtransportd's `adapters/autocert.c`
(https://github.com/fire/webtransportd). The server prints the hash at
startup; the browser client passes it to `new WebTransport(url,
{serverCertificateHashes})`, and the Godot `WebTransportPeer` does the
equivalent. Option 2 stays open for real deployments but is not a demo
requirement; option 3 does not work — browsers offer no bypass for
WebTransport.

### Consequences

- Good: zero-infrastructure demos on localhost and LANs.
- Bad: certs expire in ≤ 14 days by spec; the mint script must run
  routinely (or at server start).
- Bad: hash distribution is out-of-band; fine for demos, not a
  production trust model.
