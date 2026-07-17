// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// Minimal smoke-test input for the vendored FoundationDB actor-compiler.
// Modeled on the ACTOR syntax shown in the official Flow documentation
// (https://apple.github.io/foundationdb/flow.html#actor-compiler) — this
// file is original, not copied from any FoundationDB source.
//
// Compiled and linked against the real, vendored flow C++ runtime (see
// examples/main.cpp) as the roadmap step 0 end-to-end smoke test.

#include "flow/flow.h"

ACTOR Future<int> asyncAdd(Future<int> f, int offset) {
	int value = wait(f);
	return value + offset;
}
