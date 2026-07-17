// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// Minimal smoke-test input for the vendored FoundationDB actor-compiler.
// Modeled on the ACTOR syntax shown in the official Flow documentation
// (https://apple.github.io/foundationdb/flow.html#actor-compiler) — this
// file is original, not copied from any FoundationDB source.
//
// This only needs to survive the *transform* step (.actor.cpp -> .cpp);
// it is not compiled/linked against a flow C++ runtime yet. That is a
// later, separate increment.

ACTOR Future<int> asyncAdd(Future<int> f, int offset) {
	int value = wait(f);
	return value + offset;
}
