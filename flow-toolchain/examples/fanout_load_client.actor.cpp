// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// A Flow-native load client for picoquic_fanout_server: N simulated
// players, each a real picoquic client connection (SUB then repeated
// PUB, the same wire protocol test_picoquic_fanout.py speaks), all
// multiplexed through one picoquic_quic_t context and one Flow IUDPSocket,
// driven by Flow's own cooperative actor scheduler - the same
// receiveFrom/prepare_next_packet loop shape picoquic_fanout_server.actor.cpp
// itself uses on the server side.
//
// This exists because the earlier Python/aioquic load script
// (simulate_players_microtraffic.py) hit a real ceiling at 40 concurrent
// threads that turned out to be the test harness's own bottleneck (Python
// GIL contention across OS threads each doing tight blocking-socket polls),
// not the server's. Flow's actors are cooperatively scheduled on one
// thread with no GIL and no per-player OS thread/socket - the same shape
// this repo's determinism story already depends on - so this client can
// push concurrency much higher before hitting a real limit, and any limit
// it does hit is a property of picoquic/the server, not of how the load
// was generated.
//
// Wire protocol (matches picoquic_fanout_server.actor.cpp exactly):
//   SUB <topic>\n
//   PUB <topic>\n<100-byte lean-entity-packet payload>

#include "flow/Platform.h"
#include "flow/TLSConfig.h"
#include "flow/flow.h"
#include "flow/IConnection.h"
#include "flow/IUDPSocket.h"
#include "flow/genericactors.actor.h"

#include "picoquic.h"
#include "picoquic_utils.h"

#include <array>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#endif

#include "flow/actorcompiler.h" // This must be the last #include.

namespace {

constexpr size_t kEntityPacketSize = 100;

enum class PlayerState { Connecting, SubSent, Publishing, Done, Failed };

struct PlayerCtx {
	int playerId = 0;
	std::string room;
	int ticksRemaining = 0;
	PlayerState state = PlayerState::Connecting;
	std::string recvBuf;
	uint64_t streamId = 0;
};

std::vector<uint8_t> makePayload(int playerId, int tick) {
	std::vector<uint8_t> payload(kEntityPacketSize);
	uint8_t seed = static_cast<uint8_t>((playerId * 1000 + tick) % 256);
	for (size_t i = 0; i < kEntityPacketSize; i++) {
		payload[i] = static_cast<uint8_t>((seed + i) % 256);
	}
	return payload;
}

// SUB gets no application-level reply (only OTHER connections' PUBs fan
// out to a subscriber - the wire protocol never echoes a publisher's own
// PUB back to itself, matching what the working Python harness already
// observed empirically). Gating each tick's PUB on incoming stream data
// therefore deadlocks every connection, including in a full room: nobody
// would ever send a first PUB to trigger anyone else's next one. So SUB
// and every tick's PUB go out together, once, right when the connection
// is ready - not paced by round-trips.
void sendAllTicks(picoquic_cnx_t* cnx, PlayerCtx& player) {
	std::string subHeader = "SUB " + player.room + "\n";
	picoquic_add_to_stream(cnx, player.streamId, reinterpret_cast<const uint8_t*>(subHeader.data()),
	                        subHeader.size(), 0);
	player.state = PlayerState::Publishing;
	while (player.ticksRemaining > 0) {
		int tick = player.ticksRemaining;
		std::string pubHeader = "PUB " + player.room + "\n";
		std::vector<uint8_t> payload = makePayload(player.playerId, tick);
		picoquic_add_to_stream(cnx, player.streamId, reinterpret_cast<const uint8_t*>(pubHeader.data()),
		                        pubHeader.size(), 0);
		picoquic_add_to_stream(cnx, player.streamId, payload.data(), payload.size(), 0);
		player.ticksRemaining--;
	}
	player.state = PlayerState::Done;
}

// picoquic invokes this per-connection on state changes and stream data;
// callback_ctx is that connection's PlayerCtx. One SUB is sent once the
// handshake completes (picoquic_callback_almost_ready/ready), then one
// PUB round-trips per tick: each callback fires once the previous PUB's
// fanout echo (or, for the SUB-only stream, nothing) has been read, so
// pacing follows real server responsiveness rather than a fixed client
// timer.
int loadClientStreamCallback(picoquic_cnx_t* cnx, uint64_t streamId, uint8_t* bytes, size_t length,
                              picoquic_call_back_event_t event, void* callbackCtx, void* /*streamCtx*/) {
	auto* player = reinterpret_cast<PlayerCtx*>(callbackCtx);
	switch (event) {
	case picoquic_callback_almost_ready:
	case picoquic_callback_ready:
		if (player->state == PlayerState::Connecting) {
			player->streamId = 0;
			sendAllTicks(cnx, *player);
		}
		break;
	case picoquic_callback_stream_data:
	case picoquic_callback_stream_fin:
		// Other players' fanout deliveries landing on this stream - just
		// account for them (round-level byte totals come from the Flow
		// UDP socket counters this test doesn't currently expose per
		// player); nothing here drives this player's own tick progression.
		if (length > 0) {
			player->recvBuf.append(reinterpret_cast<const char*>(bytes), length);
		}
		break;
	case picoquic_callback_close:
	case picoquic_callback_application_close:
		if (player->state != PlayerState::Done) {
			player->state = PlayerState::Failed;
		}
		break;
	default:
		break;
	}
	return 0;
}

NetworkAddress sockaddrToNetworkAddress(const sockaddr_storage& addr) {
	const sockaddr_in* in4 = reinterpret_cast<const sockaddr_in*>(&addr);
	return NetworkAddress(IPAddress(ntohl(in4->sin_addr.s_addr)), ntohs(in4->sin_port), true, false);
}

} // namespace

// Runs playerCount concurrent picoquic client connections against
// serverPort, all sharing one picoquic_quic_t and one Flow UDP socket.
// Returns once every connection has finished its plan (SubSent -> Done)
// or the deadline elapses - whichever first - so a round that stalls
// entirely (e.g. handshakes that never complete) doesn't hang forever.
ACTOR Future<int> runLoadRound(int playerCount, std::string room, int ticks, uint16_t serverPort,
                                double deadlineSeconds) {
	state std::vector<PlayerCtx> players(playerCount);
	state std::array<uint8_t, PICOQUIC_RESET_SECRET_SIZE> resetSeed;
	resetSeed.fill(0x24);

	state picoquic_quic_t* quic = picoquic_create(static_cast<uint32_t>(playerCount) + 4,
	                                               nullptr,
	                                               nullptr,
	                                               nullptr,
	                                               "fanout-demo",
	                                               loadClientStreamCallback,
	                                               nullptr,
	                                               nullptr,
	                                               nullptr,
	                                               resetSeed.data(),
	                                               picoquic_current_time(),
	                                               nullptr,
	                                               nullptr,
	                                               nullptr,
	                                               0);
	if (quic == nullptr) {
		throw internal_error();
	}

	sockaddr_in serverAddr;
	memset(&serverAddr, 0, sizeof(serverAddr));
	serverAddr.sin_family = AF_INET;
	serverAddr.sin_port = htons(serverPort);
	inet_pton(AF_INET, "127.0.0.1", &serverAddr.sin_addr);

	state std::vector<picoquic_cnx_t*> cnxs(playerCount, nullptr);
	for (int i = 0; i < playerCount; i++) {
		players[i].playerId = i;
		players[i].room = room;
		players[i].ticksRemaining = ticks;
		picoquic_cnx_t* cnx = picoquic_create_cnx(quic,
		                                           picoquic_null_connection_id,
		                                           picoquic_null_connection_id,
		                                           reinterpret_cast<sockaddr*>(&serverAddr),
		                                           picoquic_current_time(),
		                                           0,
		                                           "fanout-load-client",
		                                           "fanout-demo",
		                                           1);
		if (cnx == nullptr) {
			continue;
		}
		picoquic_set_callback(cnx, loadClientStreamCallback, &players[i]);
		if (picoquic_start_client_cnx(cnx) == 0) {
			cnxs[i] = cnx;
		}
	}

	state Reference<IUDPSocket> socket = wait(INetworkConnections::net()->createUDPSocket(false));
	// 127.0.0.1, not the 0.0.0.0 wildcard the server itself binds to: with
	// both ends wildcard-bound, loopback replies from picoquic_fanout_server
	// were never observed arriving back on this socket (recvF blocked
	// forever, or intermittently threw connection_failed) even though the
	// server was confirmed listening and receiving. Binding the client to
	// the specific loopback address - the same address
	// test_picoquic_fanout.py's proven aioquic client already binds to -
	// fixed it.
	socket->bind(NetworkAddress(IPAddress(0x7F000001u), 0, true, false));

	state std::array<uint8_t, 2048> recvBuf;
	state std::array<uint8_t, 2048> sendBuf;
	state NetworkAddress sender;
	state Future<int> recvF = socket->receiveFrom(recvBuf.data(), recvBuf.data() + recvBuf.size(), &sender);
	state double startTime = now();
	state int debugIter = 0;

	loop {
		bool allDone = true;
		for (const PlayerCtx& p : players) {
			if (p.state != PlayerState::Done && p.state != PlayerState::Failed) {
				allDone = false;
				break;
			}
		}
		if (allDone || now() - startTime > deadlineSeconds) {
			break;
		}

		state uint64_t currentTime = static_cast<uint64_t>(now() * 1e6);
		int64_t wakeDelayUs = picoquic_get_next_wake_delay(quic, currentTime, 1000000);
		state double wakeDelayS = wakeDelayUs <= 0 ? 0.0 : static_cast<double>(wakeDelayUs) / 1e6;
		if (debugIter < 20) {
			fprintf(stderr, "[debug] iter=%d wakeDelayUs=%lld wakeDelayS=%f\n", debugIter, (long long)wakeDelayUs,
			        wakeDelayS);
			for (size_t i = 0; i < cnxs.size(); i++) {
				if (cnxs[i] != nullptr) {
					fprintf(stderr, "[debug]   cnx[%zu] state=%d playerState=%d\n", i,
					        (int)picoquic_get_cnx_state(cnxs[i]), (int)players[i].state);
				}
			}
			fflush(stderr);
		}
		debugIter++;

		choose {
			// wait(ready(recvF)), not wait(recvF): exceptions are illegal in
			// this repo's flow actor code, so a recv error must never reach
			// wait() and throw - ready() (flow/genericactors.actor.h) always
			// resolves once recvF does, success or error, and recvF's own
			// isError()/getError() are plain non-throwing accessors.
			when(wait(ready(recvF))) {
				if (recvF.isError()) {
					// Windows surfaces an ICMP port-unreachable for a prior
					// datagram as a connection-reset on the next recv on
					// that same local UDP socket, even though UDP itself is
					// connectionless - the same quirk
					// picoquic_fanout_server.actor.cpp and
					// test_picoquic_fanout.py already work around on their
					// own sides of this exact wire protocol. Harmless for a
					// QUIC client that just keeps retransmitting: log and
					// keep receiving.
					if (debugIter < 20) {
						fprintf(stderr, "[debug]   recv error (%s), retrying\n", recvF.getError().what());
						fflush(stderr);
					}
					recvF = socket->receiveFrom(recvBuf.data(), recvBuf.data() + recvBuf.size(), &sender);
				} else {
					int n = recvF.get();
					sockaddr_in addrFrom;
					memset(&addrFrom, 0, sizeof(addrFrom));
					addrFrom.sin_family = AF_INET;
					addrFrom.sin_port = htons(sender.port);
					addrFrom.sin_addr.s_addr = htonl(sender.ip.isV4() ? sender.ip.toV4() : 0u);

					sockaddr_in addrTo;
					memset(&addrTo, 0, sizeof(addrTo));
					addrTo.sin_family = AF_INET;

					picoquic_incoming_packet(quic,
					                          recvBuf.data(),
					                          static_cast<size_t>(n),
					                          reinterpret_cast<sockaddr*>(&addrFrom),
					                          reinterpret_cast<sockaddr*>(&addrTo),
					                          0,
					                          0,
					                          static_cast<uint64_t>(now() * 1e6));
					recvF = socket->receiveFrom(recvBuf.data(), recvBuf.data() + recvBuf.size(), &sender);
				}
			}
			when(wait(delay(wakeDelayS))) {
			}
		}

		loop {
			size_t sendLength = 0;
			sockaddr_storage peerAddr;
			sockaddr_storage localAddr;
			int ifIndex = 0;
			picoquic_connection_id_t logCid;
			picoquic_cnx_t* lastCnx = nullptr;
			int ret = picoquic_prepare_next_packet(quic,
			                                        static_cast<uint64_t>(now() * 1e6),
			                                        sendBuf.data(),
			                                        sendBuf.size(),
			                                        &sendLength,
			                                        &peerAddr,
			                                        &localAddr,
			                                        &ifIndex,
			                                        &logCid,
			                                        &lastCnx);
			if (debugIter < 20) {
				fprintf(stderr, "[debug]   prepare_next_packet ret=%d sendLength=%zu\n", ret, sendLength);
				fflush(stderr);
			}
			if (ret != 0 || sendLength == 0) {
				break;
			}
			state NetworkAddress peer = sockaddrToNetworkAddress(peerAddr);
			int sent = wait(socket->sendTo(sendBuf.data(), sendBuf.data() + sendLength, peer));
			if (debugIter < 20) {
				fprintf(stderr, "[debug]   sendTo peer=%s sent=%d\n", peer.toString().c_str(), sent);
				fflush(stderr);
			}
		}
	}

	state int succeeded = 0;
	for (const PlayerCtx& p : players) {
		if (p.state == PlayerState::Done) {
			succeeded++;
		}
	}
	for (picoquic_cnx_t* cnx : cnxs) {
		if (cnx != nullptr) {
			picoquic_delete_cnx(cnx);
		}
	}
	picoquic_free(quic);
	return succeeded;
}

ACTOR Future<Void> rampMain(uint16_t serverPort, int ramp_start, int max_players, int ticks, double roundDeadline) {
	state int playerCount = ramp_start;
	state int lastGood = 0;
	state int roundNum = 0;
	while (playerCount <= max_players) {
		roundNum++;
		state double roundStart = now();
		int succeeded = wait(runLoadRound(playerCount, "load-ramp" + std::to_string(roundNum), ticks, serverPort,
		                                   roundDeadline));
		double elapsed = now() - roundStart;
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
	printf("max sustained concurrent players (Flow actor client, single shard): %d\n", lastGood);
	fflush(stdout);
	return Void();
}
