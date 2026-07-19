// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// fanout_load_client is one binary with two roles, dispatched on argv -
// a CockroachDB-style deployment shape (one homogeneous executable every
// node runs, per the user's explicit preference over FoundationDB's
// heterogeneous role-specific processes coordinated by a separate
// supervisor daemon: https://github.com/v-sekai/cockroach,
// Oxide Computer's maintained CockroachDB fork, cited as the reference).
//
//   fanout_load_client <port> <rampStart> <maxPlayers> <ticks> <roundDeadline>
//     Coordinator role (default). Ramps concurrent player count, doubling
//     on success, by relaunching this same binary as a child OS process
//     per player each round (see spawnWorker/waitForWorkers below) and
//     tallying exit codes - not by running many players as concurrent
//     Flow actors in one process, which crashed (see
//     fanout_load_client.actor.cpp's header comment: 3+ simultaneous
//     independent picoquic_quic_t contexts in one process corrupt memory
//     in the vendored picoquic/mbedtls stack). One process per unit of
//     concurrent work is the same lesson FoundationDB's own production
//     deployment already encodes (one fdbserver process per core,
//     supervised by fdbmonitor) - this just gets there via relaunching
//     one binary instead of a second supervisor tool.
//
//   fanout_load_client --worker <port> <room> <playerId> <ticks> <deadlineSeconds>
//     Worker role. Runs exactly one simulated player (runOnePlayer,
//     fanout_load_client.actor.cpp) and exits 0 if it completed its SUB
//     and every PUB tick before the deadline, 1 otherwise.

#include "flow/Platform.h"
#include "flow/TLSConfig.h"
#include "flow/flow.h"
#include "flow/network.h"
#include "flow/genericactors.actor.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#else
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char** environ;
#endif

#include "flow/actorcompiler.h" // This must be the last #include.

Future<bool> runOnePlayer(int const& playerId, std::string const& room, int const& ticks, uint16_t const& serverPort,
                           double const& deadlineSeconds);

namespace {

int g_workerExitCode = 1;

} // namespace

// g_network->run() only drives whatever's scheduled; an unobserved
// exception from runOnePlayer would otherwise vanish silently, leaving
// the reactor idling forever with nothing left pending. wait(ready(f)),
// not wait(f): exceptions are illegal in this repo's flow actor code, so
// f's error must never reach wait() and throw - runOnePlayer's own setup
// failures (throw internal_error()) surface here as isError(), a plain
// non-throwing accessor, not a caught exception.
ACTOR Future<Void> runWorkerThenStop(int playerId, std::string room, int ticks, uint16_t serverPort,
                                      double deadlineSeconds) {
	state Future<bool> result = runOnePlayer(playerId, room, ticks, serverPort, deadlineSeconds);
	wait(ready(result));
	g_workerExitCode = (!result.isError() && result.get()) ? 0 : 1;
	g_network->stop();
	return Void();
}

int runWorker(uint16_t port, std::string room, int playerId, int ticks, double deadlineSeconds) {
	platformInit();
	Error::init();
	g_network = newNet2(TLSConfig());
	openTraceFile({}, 10 << 20, 100 << 20, ".", "fanout_load_client_worker");
	Future<Void> done = runWorkerThenStop(playerId, room, ticks, port, deadlineSeconds);
	g_network->run();
	return g_workerExitCode;
}

// --- Coordinator: process spawn/wait, no Flow actors needed - this role
// does no picoquic/socket I/O of its own, only OS process management. ---

namespace {

#if defined(_WIN32)
struct ChildHandle {
	PROCESS_INFORMATION pi{};
};
#else
struct ChildHandle {
	pid_t pid = -1;
};
#endif

std::string quoteArg(const std::string& arg) {
	// Every argument this coordinator passes is a number or a room name
	// this file itself generated (e.g. "load-ramp3") - none contain
	// spaces or quotes, so unconditional double-quoting is sufficient for
	// both CreateProcess's command-line parsing and a POSIX argv vector
	// (where quoting isn't needed at all, but doesn't hurt to keep args
	// uniform between the two spawn paths).
	return "\"" + arg + "\"";
}

ChildHandle spawnWorker(const std::string& execPath, uint16_t port, const std::string& room, int playerId, int ticks,
                         double deadlineSeconds) {
	std::vector<std::string> args = { execPath,
		                               "--worker",
		                               std::to_string(port),
		                               room,
		                               std::to_string(playerId),
		                               std::to_string(ticks),
		                               std::to_string(deadlineSeconds) };
	ChildHandle child;
#if defined(_WIN32)
	std::string cmdLine;
	for (size_t i = 0; i < args.size(); i++) {
		if (i > 0) {
			cmdLine += " ";
		}
		cmdLine += quoteArg(args[i]);
	}
	STARTUPINFOA si{};
	si.cb = sizeof(si);
	std::vector<char> cmdLineBuf(cmdLine.begin(), cmdLine.end());
	cmdLineBuf.push_back('\0');
	if (!CreateProcessA(nullptr, cmdLineBuf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si,
	                     &child.pi)) {
		child.pi.hProcess = nullptr;
	}
#else
	std::vector<char*> argv;
	for (std::string& a : args) {
		argv.push_back(a.data());
	}
	argv.push_back(nullptr);
	pid_t pid = -1;
	if (posix_spawn(&pid, execPath.c_str(), nullptr, nullptr, argv.data(), environ) == 0) {
		child.pid = pid;
	}
#endif
	return child;
}

bool childIsAlive(const ChildHandle& child) {
#if defined(_WIN32)
	return child.pi.hProcess != nullptr;
#else
	return child.pid > 0;
#endif
}

// Non-blocking poll; returns true and sets *exitedZero once the child has
// exited (any way), false while still running.
bool pollChild(ChildHandle& child, bool* exitedZero) {
#if defined(_WIN32)
	DWORD code = 0;
	if (!GetExitCodeProcess(child.pi.hProcess, &code)) {
		*exitedZero = false;
		return true; // treat an unqueryable handle as done-and-failed
	}
	if (code == STILL_ACTIVE) {
		return false;
	}
	*exitedZero = (code == 0);
	return true;
#else
	int status = 0;
	pid_t r = waitpid(child.pid, &status, WNOHANG);
	if (r == 0) {
		return false;
	}
	*exitedZero = WIFEXITED(status) && WEXITSTATUS(status) == 0;
	return true;
#endif
}

void forceKill(ChildHandle& child) {
#if defined(_WIN32)
	if (child.pi.hProcess != nullptr) {
		TerminateProcess(child.pi.hProcess, 1);
		WaitForSingleObject(child.pi.hProcess, 1000);
	}
#else
	if (child.pid > 0) {
		kill(child.pid, SIGKILL);
		int status = 0;
		waitpid(child.pid, &status, 0);
	}
#endif
}

void closeChild(ChildHandle& child) {
#if defined(_WIN32)
	if (child.pi.hProcess != nullptr) {
		CloseHandle(child.pi.hProcess);
	}
	if (child.pi.hThread != nullptr) {
		CloseHandle(child.pi.hThread);
	}
#endif
}

// Spawns playerCount workers and waits for all of them, up to
// deadlineSeconds total for the round (not per child) - stragglers past
// the deadline are force-killed and counted as failed, so one hung
// connection can't hang the whole ramp.
int runRound(const std::string& execPath, uint16_t port, const std::string& room, int playerCount, int ticks,
             double deadlineSeconds) {
	std::vector<ChildHandle> children;
	children.reserve(playerCount);
	for (int i = 0; i < playerCount; i++) {
		children.push_back(spawnWorker(execPath, port, room, i, ticks, deadlineSeconds));
	}

	std::vector<bool> reaped(playerCount, false);
	std::vector<bool> succeeded(playerCount, false);
	auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(deadlineSeconds + 1.0);

	bool allReaped = false;
	while (!allReaped && std::chrono::steady_clock::now() < deadline) {
		allReaped = true;
		for (int i = 0; i < playerCount; i++) {
			if (reaped[i] || !childIsAlive(children[i])) {
				continue;
			}
			bool exitedZero = false;
			if (pollChild(children[i], &exitedZero)) {
				reaped[i] = true;
				succeeded[i] = exitedZero;
				closeChild(children[i]);
			} else {
				allReaped = false;
			}
		}
		if (!allReaped) {
			std::this_thread::sleep_for(std::chrono::milliseconds(10));
		}
	}

	int successCount = 0;
	for (int i = 0; i < playerCount; i++) {
		if (!reaped[i] && childIsAlive(children[i])) {
			forceKill(children[i]);
			closeChild(children[i]);
		} else if (succeeded[i]) {
			successCount++;
		}
	}
	return successCount;
}

void runCoordinator(uint16_t port, int rampStart, int maxPlayers, int ticks, double roundDeadline) {
	platformInit();
	std::string execPath = getExecPath();

	int playerCount = rampStart;
	int lastGood = 0;
	int roundNum = 0;
	while (playerCount <= maxPlayers) {
		roundNum++;
		std::string room = "load-ramp" + std::to_string(roundNum);
		auto roundStart = std::chrono::steady_clock::now();
		int succeeded = runRound(execPath, port, room, playerCount, ticks, roundDeadline);
		double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - roundStart).count();
		printf("round %d: %d players, %d succeeded, %.2fs elapsed\n", roundNum, playerCount, succeeded, elapsed);
		fflush(stdout);
		double failureRate = 1.0 - (static_cast<double>(succeeded) / playerCount);
		if (failureRate > 0.1) {
			printf("round %d failure rate %.0f%% exceeds 10%%; stopping ramp\n", roundNum, failureRate * 100.0);
			fflush(stdout);
			break;
		}
		lastGood = playerCount;
		playerCount *= 2;
	}
	printf("max sustained concurrent players (separate OS processes): %d\n", lastGood);
	fflush(stdout);
}

} // namespace

int main(int argc, char** argv) {
	if (argc > 1 && std::string(argv[1]) == "--worker") {
		uint16_t port = argc > 2 ? static_cast<uint16_t>(atoi(argv[2])) : 4433;
		std::string room = argc > 3 ? argv[3] : "load-worker";
		int playerId = argc > 4 ? atoi(argv[4]) : 0;
		int ticks = argc > 5 ? atoi(argv[5]) : 5;
		double deadlineSeconds = argc > 6 ? atof(argv[6]) : 10.0;
		return runWorker(port, room, playerId, ticks, deadlineSeconds);
	}

	uint16_t serverPort = argc > 1 ? static_cast<uint16_t>(atoi(argv[1])) : 4433;
	int rampStart = argc > 2 ? atoi(argv[2]) : 20;
	int maxPlayers = argc > 3 ? atoi(argv[3]) : 5000;
	int ticks = argc > 4 ? atoi(argv[4]) : 5;
	double roundDeadline = argc > 5 ? atof(argv[5]) : 10.0;
	runCoordinator(serverPort, rampStart, maxPlayers, ticks, roundDeadline);
	return 0;
}
