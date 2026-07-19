// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee
//
// A Flow actor that terminates QUIC directly (via vendored picoquic) and
// relays a text SUB/PUB topic protocol between connections. All fanout
// logic - which connections are subscribed to which topic, who receives a
// PUB - lives in the fanout-core Lean4 kernel (fanout-core/); this file owns
// I/O only: the QUIC context, the UDP socket, the wait/timer loop, and the
// topic-name <-> room-id / connection-id <-> delivery-stream tables that
// let the Lean core operate on plain integers instead of QUIC objects.
//
// Wire protocol, one line per stream:
//   SUB <topic>\n
//   PUB <topic>\n<100-byte lean-entity-packet payload>
// A subscriber receives each PUB payload verbatim, pushed back on the same
// bidirectional stream it sent its SUB on.

#include "fanout_core_ffi.h"
#include "sketch_core_ffi.h"

#include "flow/Platform.h"
#include "flow/TLSConfig.h"
#include "flow/flow.h"
#include "flow/IConnection.h"
#include "flow/IUDPSocket.h"
#include "flow/genericactors.actor.h"

#include "picoquic.h"

#include <array>
#include <cstring>
#include <unordered_map>
#include <string>

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

// lean-entity-packet's fixed wire size (v-sekai-multiplayer-fabric/lean-entity-packet).
constexpr size_t kEntityPacketSize = 100;

uint64_t connIdOf(picoquic_cnx_t* cnx) {
	return reinterpret_cast<uint64_t>(cnx);
}

NetworkAddress sockaddrToNetworkAddress(const sockaddr_storage& addr) {
	const sockaddr_in* in4 = reinterpret_cast<const sockaddr_in*>(&addr);
	return NetworkAddress(IPAddress(ntohl(in4->sin_addr.s_addr)), ntohs(in4->sin_port), true, false);
}

// Per-stream parse state: buffers bytes until the "SUB <topic>\n",
// "PUB <topic>\n", or "SKB <topic>\n" header line is complete, then (for
// PUB) buffers the fixed-size payload, or (for SKB) parses length-prefixed
// CSP1 sketch frames.
struct StreamState {
	std::string buf;
	bool headerParsed = false;
	bool isPub = false;
	bool isSketch = false;
	std::string topic;
	uint64_t roomId = 0;
};

// A sketch frame is [len u32 LE][len bytes of CSP1]. Cap len well above any
// real stroke chunk but low enough that a corrupt length can't balloon the
// stream buffer.
constexpr size_t kMaxSketchFrame = 1 << 20;

// One process = one shard = one fanout-core instance, so this state is a
// single global, guarded by nothing: picoquic invokes the stream callback
// from Flow's own reactor thread only, called synchronously out of the
// bridge actor below - there is no concurrent access to race against.
struct BridgeState {
	std::unordered_map<std::string, uint64_t> topicToRoom;
	// conn_id -> (cnx, stream_id) of the stream a connection last SUBed on,
	// i.e. where a PUB fanned out to that connection gets written.
	std::unordered_map<uint64_t, std::pair<picoquic_cnx_t*, uint64_t>> delivery;
	std::unordered_map<picoquic_cnx_t*, std::unordered_map<uint64_t, StreamState>> streams;
};

uint64_t getOrCreateRoom(BridgeState& state, const std::string& topic) {
	auto it = state.topicToRoom.find(topic);
	if (it != state.topicToRoom.end()) {
		return it->second;
	}
	lean_object* res = fanout_alloc_room();
	uint64_t roomId = FANOUT_CORE_SENTINEL;
	if (lean_io_result_is_ok(res)) {
		roomId = lean_unbox_uint64(lean_io_result_get_value(res));
	}
	lean_dec_ref(res);
	if (roomId != FANOUT_CORE_SENTINEL) {
		state.topicToRoom.emplace(topic, roomId);
	}
	return roomId;
}

void handleSub(BridgeState& state, picoquic_cnx_t* cnx, uint64_t streamId, const std::string& topic) {
	uint64_t roomId = getOrCreateRoom(state, topic);
	if (roomId == FANOUT_CORE_SENTINEL) {
		return;
	}
	uint64_t connId = connIdOf(cnx);
	state.delivery[connId] = { cnx, streamId };
	lean_object* res = fanout_sub(roomId, connId);
	lean_dec_ref(res);
}

// SKB: subscribe like SUB (so sketch frames fan out on this stream), then
// replay the room's accepted history so a late joiner converges to the same
// graph as everyone who was present from the start.
void handleSketchSub(BridgeState& state, picoquic_cnx_t* cnx, uint64_t streamId, StreamState& streamState) {
	uint64_t roomId = getOrCreateRoom(state, streamState.topic);
	if (roomId == FANOUT_CORE_SENTINEL) {
		return;
	}
	streamState.roomId = roomId;
	uint64_t connId = connIdOf(cnx);
	state.delivery[connId] = { cnx, streamId };
	lean_object* res = fanout_sub(roomId, connId);
	lean_dec_ref(res);
	for (const std::vector<uint8_t>& packet : sketchCoreHistory(roomId)) {
		uint8_t lenPrefix[4] = {
			static_cast<uint8_t>(packet.size()),
			static_cast<uint8_t>(packet.size() >> 8),
			static_cast<uint8_t>(packet.size() >> 16),
			static_cast<uint8_t>(packet.size() >> 24),
		};
		picoquic_add_to_stream(cnx, streamId, lenPrefix, sizeof(lenPrefix), 0);
		picoquic_add_to_stream(cnx, streamId, packet.data(), packet.size(), 0);
	}
}

// One complete sketch frame arrived: validate + dedup through the Lean core;
// if accepted, relay the identical frame to every other subscriber.
void handleSketchFrame(BridgeState& state, picoquic_cnx_t* cnx, const StreamState& streamState,
                       const uint8_t* frame, size_t frameLen) {
	if (!sketchCoreApplyPacket(streamState.roomId, frame, frameLen)) {
		return; // invalid or duplicate; nothing to relay.
	}
	uint64_t connId = connIdOf(cnx);
	lean_object* res = fanout_pub_targets(streamState.roomId, connId);
	if (!lean_io_result_is_ok(res)) {
		lean_dec_ref(res);
		return;
	}
	uint8_t lenPrefix[4] = {
		static_cast<uint8_t>(frameLen),
		static_cast<uint8_t>(frameLen >> 8),
		static_cast<uint8_t>(frameLen >> 16),
		static_cast<uint8_t>(frameLen >> 24),
	};
	lean_object* arr = lean_io_result_get_value(res);
	size_t n = lean_array_size(arr);
	for (size_t i = 0; i < n; i++) {
		uint64_t targetConnId = lean_unbox_uint64(lean_array_get_core(arr, i));
		auto it = state.delivery.find(targetConnId);
		if (it == state.delivery.end()) {
			continue;
		}
		picoquic_add_to_stream(it->second.first, it->second.second, lenPrefix, sizeof(lenPrefix), 0);
		picoquic_add_to_stream(it->second.first, it->second.second, frame, frameLen, 0);
	}
	lean_dec_ref(res);
}

void handlePub(BridgeState& state, picoquic_cnx_t* cnx, const std::string& topic, const uint8_t* payload,
               size_t payloadLen) {
	uint64_t roomId = getOrCreateRoom(state, topic);
	if (roomId == FANOUT_CORE_SENTINEL) {
		return;
	}
	uint64_t connId = connIdOf(cnx);
	lean_object* res = fanout_pub_targets(roomId, connId);
	if (!lean_io_result_is_ok(res)) {
		lean_dec_ref(res);
		return;
	}
	lean_object* arr = lean_io_result_get_value(res);
	size_t n = lean_array_size(arr);
	for (size_t i = 0; i < n; i++) {
		uint64_t targetConnId = lean_unbox_uint64(lean_array_get_core(arr, i));
		auto it = state.delivery.find(targetConnId);
		if (it == state.delivery.end()) {
			continue; // subscriber's connection/stream is gone; skip it.
		}
		picoquic_add_to_stream(it->second.first, it->second.second, payload, payloadLen, 0);
	}
	lean_dec_ref(res);
}

void cleanupStream(BridgeState& state, picoquic_cnx_t* cnx, uint64_t streamId, const StreamState& streamState) {
	uint64_t connId = connIdOf(cnx);
	auto it = state.delivery.find(connId);
	if (it != state.delivery.end() && it->second.first == cnx && it->second.second == streamId) {
		state.delivery.erase(it);
	}
	if (streamState.headerParsed && !streamState.isPub) {
		auto roomIt = state.topicToRoom.find(streamState.topic);
		if (roomIt != state.topicToRoom.end()) {
			lean_object* res = fanout_unsub(roomIt->second, connId);
			lean_dec_ref(res);
		}
	}
}

// Consumes as much of streamState.buf as currently parses; returns once no
// further progress can be made (more bytes needed).
void pumpStream(BridgeState& state, picoquic_cnx_t* cnx, uint64_t streamId, StreamState& streamState) {
	for (;;) {
		if (!streamState.headerParsed) {
			size_t nl = streamState.buf.find('\n');
			if (nl == std::string::npos) {
				return;
			}
			std::string header = streamState.buf.substr(0, nl);
			streamState.buf.erase(0, nl + 1);
			size_t sp = header.find(' ');
			if (sp == std::string::npos) {
				return; // malformed header; stop parsing this stream.
			}
			std::string verb = header.substr(0, sp);
			streamState.topic = header.substr(sp + 1);
			streamState.headerParsed = true;
			if (verb == "SUB") {
				streamState.isPub = false;
				handleSub(state, cnx, streamId, streamState.topic);
			} else if (verb == "PUB") {
				streamState.isPub = true;
			} else if (verb == "SKB") {
				streamState.isSketch = true;
				handleSketchSub(state, cnx, streamId, streamState);
			} else {
				return; // unknown verb; stop parsing this stream.
			}
		} else if (streamState.isSketch) {
			// Length-prefixed CSP1 frames, indefinitely many per stream.
			if (streamState.buf.size() < 4) {
				return;
			}
			const uint8_t* b = reinterpret_cast<const uint8_t*>(streamState.buf.data());
			size_t frameLen = static_cast<size_t>(b[0]) | (static_cast<size_t>(b[1]) << 8) |
			                  (static_cast<size_t>(b[2]) << 16) | (static_cast<size_t>(b[3]) << 24);
			if (frameLen > kMaxSketchFrame) {
				return; // corrupt length; stop parsing this stream.
			}
			if (streamState.buf.size() < 4 + frameLen) {
				return;
			}
			handleSketchFrame(state, cnx, streamState,
			                  reinterpret_cast<const uint8_t*>(streamState.buf.data()) + 4, frameLen);
			streamState.buf.erase(0, 4 + frameLen);
		} else if (streamState.isPub) {
			if (streamState.buf.size() < kEntityPacketSize) {
				return;
			}
			handlePub(state, cnx, streamState.topic,
			          reinterpret_cast<const uint8_t*>(streamState.buf.data()), kEntityPacketSize);
			streamState.buf.erase(0, kEntityPacketSize);
			// One PUB payload per stream in this protocol; wait for a fresh header.
			streamState.headerParsed = false;
		} else {
			return; // SUB stream: nothing further to parse.
		}
	}
}

int fanoutStreamCallback(picoquic_cnx_t* cnx, uint64_t streamId, uint8_t* bytes, size_t length,
                          picoquic_call_back_event_t event, void* callbackCtx, void* /*streamCtx*/) {
	auto* state = reinterpret_cast<BridgeState*>(callbackCtx);
	switch (event) {
	case picoquic_callback_stream_data:
	case picoquic_callback_stream_fin: {
		StreamState& streamState = state->streams[cnx][streamId];
		if (length > 0) {
			streamState.buf.append(reinterpret_cast<const char*>(bytes), length);
		}
		pumpStream(*state, cnx, streamId, streamState);
		if (event == picoquic_callback_stream_fin) {
			cleanupStream(*state, cnx, streamId, streamState);
			state->streams[cnx].erase(streamId);
		}
		break;
	}
	case picoquic_callback_stream_reset: {
		auto cnxIt = state->streams.find(cnx);
		if (cnxIt != state->streams.end()) {
			auto streamIt = cnxIt->second.find(streamId);
			if (streamIt != cnxIt->second.end()) {
				cleanupStream(*state, cnx, streamId, streamIt->second);
				cnxIt->second.erase(streamIt);
			}
		}
		break;
	}
	case picoquic_callback_close:
	case picoquic_callback_application_close: {
		auto cnxIt = state->streams.find(cnx);
		if (cnxIt != state->streams.end()) {
			for (auto& [sid, streamState] : cnxIt->second) {
				cleanupStream(*state, cnx, sid, streamState);
			}
			state->streams.erase(cnxIt);
		}
		break;
	}
	default:
		break;
	}
	return 0;
}

} // namespace

ACTOR Future<Void> fanoutServer(uint16_t port, std::string certPath, std::string keyPath) {
	state BridgeState bridgeState;
	state std::array<uint8_t, PICOQUIC_RESET_SECRET_SIZE> resetSeed;
	resetSeed.fill(0x42);

	// 64 (picoquic's own common default) was a real, unintentional ceiling
	// found while load-testing this server with fanout_load_client - not
	// yet actually hit (that testing found a lower, client/OS-side ceiling
	// first: see flow-toolchain/examples/fanout_load_client.actor.cpp's
	// header comment), but worth removing proactively so it isn't the
	// next one found. 2048 is comfortably above any near-term target
	// without committing to a specific fabric-scale number - that number
	// depends on the still-unstarted Hilbert-curve interest/authority
	// redesign (docs/decisions/0008-fiedler-scale-constants-and-fabric-interest-authority.md),
	// not on this single-shard server's own raw connection handling.
	state picoquic_quic_t* quic = picoquic_create(2048,
	                                               certPath.c_str(),
	                                               keyPath.c_str(),
	                                               nullptr,
	                                               "fanout-demo",
	                                               fanoutStreamCallback,
	                                               &bridgeState,
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

	state Reference<IUDPSocket> socket = wait(INetworkConnections::net()->createUDPSocket(false));
	socket->bind(NetworkAddress(IPAddress(0u), port, true, false));

	state std::array<uint8_t, 2048> recvBuf;
	state std::array<uint8_t, 2048> sendBuf;

	// Exactly one receiveFrom() stays outstanding at a time: recreating it every
	// loop iteration (even when the timer branch below wins the race) would
	// abandon a still-pending read and could silently drop whatever packet
	// eventually completes it.
	state NetworkAddress sender;
	state Future<int> recvF = socket->receiveFrom(recvBuf.data(), recvBuf.data() + recvBuf.size(), &sender);

	loop {
		state uint64_t currentTime = static_cast<uint64_t>(now() * 1e6);
		int64_t wakeDelayUs = picoquic_get_next_wake_delay(quic, currentTime, 1000000);
		state double wakeDelayS = wakeDelayUs <= 0 ? 0.0 : static_cast<double>(wakeDelayUs) / 1e6;

		choose {
			// wait(ready(recvF)), not wait(recvF): exceptions are illegal in
			// this repo's flow actor code, so a recv error must never reach
			// wait() and throw - ready() (flow/genericactors.actor.h) always
			// resolves once recvF does, success or error, and recvF's own
			// isError()/getError() are plain non-throwing accessors. Before
			// this guard, an uncaught Windows connection-reset here (see
			// below) killed this whole `loop` actor: the process stayed
			// alive (nothing else keeps g_network->run() busy) but its
			// listening socket was gone with it, so the server looked alive
			// while answering no traffic at all.
			when(wait(ready(recvF))) {
				if (recvF.isError()) {
					// Windows surfaces an ICMP port-unreachable for a prior
					// outbound datagram (e.g. this server's own reply racing
					// a client that already gave up and closed its ephemeral
					// port) as a connection-reset on this socket's next
					// recv, even though UDP itself is connectionless -
					// test_picoquic_fanout.py already works around the
					// identical quirk on the client side. Log and keep
					// receiving regardless of the specific error - this recv
					// loop must never die from a transient socket error.
					TraceEvent(SevWarn, "FanoutRecvError").error(recvF.getError());
					recvF = socket->receiveFrom(recvBuf.data(), recvBuf.data() + recvBuf.size(), &sender);
				} else if (sender.ip.isV6()) {
					// Defensive: this socket is v4-only, but macOS has been seen
					// delivering a v6-form sender; toV4() on it would throw
					// bad_variant_access and kill this loop actor. Drop the
					// datagram instead - QUIC retransmission recovers it.
					TraceEvent(SevWarnAlways, "FanoutV6SenderSkipped").detail("From", sender);
					recvF = socket->receiveFrom(recvBuf.data(), recvBuf.data() + recvBuf.size(), &sender);
				} else {
					int n = recvF.get();
					sockaddr_in addrFrom;
					memset(&addrFrom, 0, sizeof(addrFrom));
					addrFrom.sin_family = AF_INET;
					addrFrom.sin_port = htons(sender.port);
					addrFrom.sin_addr.s_addr = htonl(sender.ip.toV4());

					sockaddr_in addrTo;
					memset(&addrTo, 0, sizeof(addrTo));
					addrTo.sin_family = AF_INET;
					addrTo.sin_port = htons(port);

					int incomingRet = picoquic_incoming_packet(quic,
					                          recvBuf.data(),
					                          static_cast<size_t>(n),
					                          reinterpret_cast<sockaddr*>(&addrFrom),
					                          reinterpret_cast<sockaddr*>(&addrTo),
					                          0,
					                          0,
					                          static_cast<uint64_t>(now() * 1e6));
					if (incomingRet != 0) {
						TraceEvent(SevWarn, "FanoutIncomingPacketFailed")
						    .detail("Ret", incomingRet)
						    .detail("Bytes", n)
						    .detail("From", sender);
					}
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
			if (ret != 0) {
				TraceEvent(SevWarn, "FanoutPrepareNextPacketFailed").detail("Ret", ret);
				break;
			}
			if (sendLength == 0) {
				break;
			}
			state NetworkAddress peer = sockaddrToNetworkAddress(peerAddr);
			int sent = wait(socket->sendTo(sendBuf.data(), sendBuf.data() + sendLength, peer));
			if (sent < 0) {
				TraceEvent(SevWarn, "FanoutSendToFailed").detail("Ret", sent).detail("Peer", peer);
			}
		}
	}
}
