// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee

#include "flow/Platform.h"
#include "flow/TLSConfig.h"
#include "flow/flow.h"
#include "flow/network.h"
#include "flow/genericactors.actor.h"

#include <cstdio>
#include <cstdlib>
#include <string>

#include "flow/actorcompiler.h" // This must be the last #include.

Future<Void> rampMain(uint16_t const& serverPort, int const& ramp_start, int const& max_players, int const& ticks,
                       double const& roundDeadline);

// g_network->run() only drives whatever's scheduled; an exception inside
// ramp that nothing else waits on would otherwise vanish silently, leaving
// the reactor idling forever with nothing left pending - report it here so
// a real bug shows up as a message, not a silent hang. wait(ready(ramp)),
// not wait(ramp): exceptions are illegal in this repo's flow actor code,
// so ramp's error must never reach wait() and throw.
ACTOR Future<Void> runThenStop(Future<Void> ramp) {
	wait(ready(ramp));
	if (ramp.isError()) {
		fprintf(stderr, "[fatal] ramp failed: %s\n", ramp.getError().what());
		fflush(stderr);
	}
	g_network->stop();
	return Void();
}

int main(int argc, char** argv) {
	uint16_t serverPort = argc > 1 ? static_cast<uint16_t>(atoi(argv[1])) : 4433;
	int rampStart = argc > 2 ? atoi(argv[2]) : 20;
	int maxPlayers = argc > 3 ? atoi(argv[3]) : 5000;
	int ticks = argc > 4 ? atoi(argv[4]) : 5;
	double roundDeadline = argc > 5 ? atof(argv[5]) : 10.0;

	platformInit();
	Error::init();
	g_network = newNet2(TLSConfig());
	openTraceFile({}, 10 << 20, 100 << 20, ".", "fanout_load_client");
	Future<Void> done = runThenStop(rampMain(serverPort, rampStart, maxPlayers, ticks, roundDeadline));
	g_network->run();
	return 0;
}
