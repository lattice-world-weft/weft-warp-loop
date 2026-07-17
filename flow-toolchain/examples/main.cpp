// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// Minimal end-to-end smoke test: run one real actor (asyncAdd, from
// hello_actor.actor.cpp) through the real, vendored FoundationDB flow C++
// runtime. g_network is initialized (required by flow's tracing/clock
// machinery) but its event loop is never run: the input Future is already
// fulfilled before the actor observes it, so the actor-compiler's generated
// code takes its synchronous "already ready" path and completes without
// needing the reactor scheduler at all.

#include "flow/flow.h"
#include "flow/network.h"
#include "flow/TLSConfig.h"

#include <cstdio>
#include <cstdlib>

Future<int> asyncAdd(Future<int> f, int offset);

int main() {
	g_network = newNet2(TLSConfig());

	Promise<int> p;
	Future<int> f = p.getFuture();
	p.send(5);

	Future<int> result = asyncAdd(f, 10);

	if (!result.isReady()) {
		std::fprintf(stderr, "FAIL: asyncAdd did not complete synchronously\n");
		return 1;
	}
	if (result.isError()) {
		std::fprintf(stderr, "FAIL: asyncAdd errored: %s\n", result.getError().what());
		return 1;
	}

	int value = result.get();
	if (value != 15) {
		std::fprintf(stderr, "FAIL: expected 15, got %d\n", value);
		return 1;
	}

	std::printf("OK: asyncAdd(5, 10) = %d\n", value);
	return 0;
}
