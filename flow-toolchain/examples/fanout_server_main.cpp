// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee

#include "fanout_core_ffi.h"

#include "flow/Platform.h"
#include "flow/TLSConfig.h"
#include "flow/flow.h"
#include "flow/network.h"

#include <cstdlib>
#include <string>

Future<Void> fanoutServer(uint16_t const& port, std::string const& certPath, std::string const& keyPath);

int main(int argc, char** argv) {
	uint16_t port = argc > 1 ? static_cast<uint16_t>(atoi(argv[1])) : 4433;
	// secp256r1 (ECDSA), not the RSA cert.pem/key.pem: the vendored TLS stack
	// builds without picotls's OpenSSL backend, and its minicrypto/mbedtls
	// signers can't produce the RSA-PSS CertificateVerify TLS 1.3 requires -
	// clients reject the handshake with alert 51 (decrypt_error).
	std::string certPath = argc > 2 ? argv[2] : "thirdparty/picoquic/certs/secp256r1/cert.pem";
	std::string keyPath = argc > 3 ? argv[3] : "thirdparty/picoquic/certs/secp256r1/key.pem";

	platformInit();
	Error::init();
	fanoutCoreInitialize(64);

	g_network = newNet2(TLSConfig());
	openTraceFile({}, 10 << 20, 100 << 20, ".", "fanout_server");
	Future<Void> serverLoop = fanoutServer(port, certPath, keyPath);
	g_network->run();
	return 0;
}
