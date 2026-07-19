// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// A Flow-native load client for picoquic_fanout_server: one simulated
// player, a real picoquic client connection (SUB then repeated PUB, the
// same wire protocol test_picoquic_fanout.py speaks) over its own Flow
// IUDPSocket and picoquic_quic_t context - the same receiveFrom/
// prepare_next_packet loop shape picoquic_fanout_server.actor.cpp itself
// uses on the server side.
//
// This exists because the earlier Python/aioquic load script
// (simulate_players_microtraffic.py) hit a real ceiling at 40 concurrent
// threads that turned out to be the test harness's own bottleneck (Python
// GIL contention across OS threads each doing tight blocking-socket polls),
// not the server's.
//
// One quic_t/socket/connection per OS process, not per in-process actor:
// an earlier version ran many players as concurrent Flow actors sharing
// one process, first with one shared picoquic_quic_t (which meant a burst
// of connections all shared one local 4-tuple and reliably triggered a
// storm of Windows ICMP-port-unreachable/connection-reset notifications),
// then with each player getting its own independent picoquic_quic_t
// within that same process - which crashed: 3+ simultaneous independent
// contexts corrupt memory in the vendored picoquic/mbedtls stack (clean
// failure at 3, hard segfault at 4+), a usage pattern nothing else in
// this codebase has ever exercised (every other tool here creates exactly
// one context per process). fanout_load_client_main.actor.cpp's
// coordinator role gets process-level isolation the way FoundationDB
// itself does in production - one process per unit of concurrent work,
// not many units sharing one process's memory - by relaunching this same
// binary as a child OS process per player, matching the user's explicit
// CockroachDB-over-FoundationDB deployment preference (one homogeneous
// executable for every role, not a supervisor coordinating heterogeneous
// role-specific processes). This file is that binary's worker role: it
// only ever handles one player.
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

enum class PlayerState { Connecting, Publishing, Done, Failed };

struct PlayerCtx {
	int playerId = 0;
	std::string room;
	int ticksRemaining = 0;
	PlayerState state = PlayerState::Connecting;
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
// therefore deadlocks every connection: nobody would ever send a first
// PUB to trigger anyone else's next one. So SUB and every tick's PUB go
// out together, once, right when the connection is ready - not paced by
// round-trips that don't exist in this protocol.
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
		// Other players' fanout deliveries landing on this stream; nothing
		// to do here beyond acknowledging receipt (picoquic already does
		// that at the transport level) - this player's own progression
		// doesn't depend on it.
		(void)bytes;
		(void)length;
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

// One simulated player: its own picoquic_quic_t, its own Flow UDP socket,
// one connection. Returns true once its SUB and all its PUB ticks have
// been queued and the connection reached picoquic_state_ready; false if
// deadlineSeconds elapses first.
ACTOR Future<bool> runOnePlayer(int playerId, std::string room, int ticks, uint16_t serverPort,
                                 double deadlineSeconds) {
	state PlayerCtx player;
	player.playerId = playerId;
	player.room = room;
	player.ticksRemaining = ticks;

	state std::array<uint8_t, PICOQUIC_RESET_SECRET_SIZE> resetSeed;
	resetSeed.fill(static_cast<uint8_t>(0x24 + (playerId & 0xff)));

	state picoquic_quic_t* quic = picoquic_create(4,
	                                               nullptr,
	                                               nullptr,
	                                               nullptr,
	                                               "fanout-demo",
	                                               loadClientStreamCallback,
	                                               &player,
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

	state picoquic_cnx_t* cnx = picoquic_create_cnx(quic,
	                                                 picoquic_null_connection_id,
	                                                 picoquic_null_connection_id,
	                                                 reinterpret_cast<sockaddr*>(&serverAddr),
	                                                 picoquic_current_time(),
	                                                 0,
	                                                 "fanout-load-client",
	                                                 "fanout-demo",
	                                                 1);
	if (cnx == nullptr || picoquic_start_client_cnx(cnx) != 0) {
		picoquic_free(quic);
		throw internal_error();
	}

	state Reference<IUDPSocket> socket = wait(INetworkConnections::net()->createUDPSocket(false));
	// 127.0.0.1, not the 0.0.0.0 wildcard the server itself binds to: with
	// both ends wildcard-bound, loopback replies from picoquic_fanout_server
	// were never observed arriving back reliably, even though the server
	// was confirmed listening and receiving. Binding the client to the
	// specific loopback address - what test_picoquic_fanout.py's proven
	// aioquic client already does - fixed it.
	socket->bind(NetworkAddress(IPAddress(0x7F000001u), 0, true, false));

	state std::array<uint8_t, 2048> recvBuf;
	state std::array<uint8_t, 2048> sendBuf;
	state NetworkAddress sender;
	state Future<int> recvF = socket->receiveFrom(recvBuf.data(), recvBuf.data() + recvBuf.size(), &sender);
	state double startTime = now();

	loop {
		if (player.state == PlayerState::Done || player.state == PlayerState::Failed ||
		    now() - startTime > deadlineSeconds) {
			break;
		}

		state uint64_t currentTime = static_cast<uint64_t>(now() * 1e6);
		int64_t wakeDelayUs = picoquic_get_next_wake_delay(quic, currentTime, 1000000);
		state double wakeDelayS = wakeDelayUs <= 0 ? 0.0 : static_cast<double>(wakeDelayUs) / 1e6;

		choose {
			// wait(ready(recvF)), not wait(recvF): exceptions are illegal in
			// this repo's flow actor code, so a recv error must never reach
			// wait() and throw - ready() (flow/genericactors.actor.h) always
			// resolves once recvF does, success or error, and recvF's own
			// isError()/getError() are plain non-throwing accessors.
			when(wait(ready(recvF))) {
				if (recvF.isError()) {
					// Windows surfaces an ICMP port-unreachable for a prior
					// datagram as a connection-reset on this socket's next
					// recv, even though UDP itself is connectionless -
					// test_picoquic_fanout.py and
					// picoquic_fanout_server.actor.cpp both already work
					// around the identical thing on their own sockets.
					// Harmless for a QUIC client that keeps retransmitting:
					// drop it and keep receiving.
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
			if (ret != 0 || sendLength == 0) {
				break;
			}
			state NetworkAddress peer = sockaddrToNetworkAddress(peerAddr);
			int sent = wait(socket->sendTo(sendBuf.data(), sendBuf.data() + sendLength, peer));
			(void)sent;
		}
	}

	bool succeeded = player.state == PlayerState::Done;
	picoquic_delete_cnx(cnx);
	picoquic_free(quic);
	return succeeded;
}
