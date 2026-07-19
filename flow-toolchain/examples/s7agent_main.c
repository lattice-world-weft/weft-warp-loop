/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 K. S. Ernest (iFire) Lee */
/* Native s7 devtool runner (ADR 0006 item 10): loads a Scheme script with
 * the HTTP FFI (s7_http_ffi.c) installed. Used for artifacts-mmo-agent.scm.
 * Not part of the sandboxed RISC-V guest tier - real network I/O is the
 * point here, which the guest tier deliberately has none of. */
#include "s7.h"
#include <stdio.h>

void install_http_ffi(s7_scheme *sc);

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: %s file.scm\n", argv[0]);
		return 1;
	}
	s7_scheme *s7 = s7_init();
	install_http_ffi(s7);
	if (!s7_load(s7, argv[1])) {
		fprintf(stderr, "load failed: %s\n", argv[1]);
		return 1;
	}
	return 0;
}
