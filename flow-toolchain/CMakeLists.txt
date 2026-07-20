cmake_minimum_required(VERSION 3.20)
project(weft_warp_loop_flow_runtime CXX C ASM)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Threads REQUIRED)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_package(OpenSSL REQUIRED)
find_package(fmt REQUIRED)

if(WIN32)
  find_package(Boost 1.86.0 REQUIRED
    COMPONENTS filesystem iostreams serialization system program_options url
    CONFIG)
  add_library(boost_target INTERFACE)
  target_link_libraries(boost_target INTERFACE
    Boost::boost Boost::filesystem Boost::iostreams Boost::serialization
    Boost::system Boost::url)
else()
  find_package(Boost 1.86.0 REQUIRED
    COMPONENTS context filesystem iostreams program_options serialization system url
    CONFIG)
  add_library(boost_target INTERFACE)
  target_link_libraries(boost_target INTERFACE
    Boost::boost Boost::context Boost::filesystem Boost::iostreams
    Boost::serialization Boost::system Boost::url)
endif()

# --- contrib sibling libraries (vendored from apple/foundationdb's contrib/) ---
add_subdirectory(contrib/SimpleOpt)
add_subdirectory(contrib/libb64)
add_subdirectory(contrib/stacktrace)
add_subdirectory(contrib/crc32)
if(UNIX AND NOT APPLE)
  add_subdirectory(contrib/folly_memcpy)
endif()

# --- codegen: ApiVersion.h / SourceVersion.h / config.h ---
set(CODEGEN_INCLUDE_DIR "${CMAKE_CURRENT_BINARY_DIR}/include")
file(MAKE_DIRECTORY "${CODEGEN_INCLUDE_DIR}/flow")

include(flow/ApiVersions.cmake)
set(CURRENT_GIT_VERSION "weft-warp-loop-extraction")
# config.h.cmake defines _WIN32_WINNT/WINVER from this; an unset value leaves
# both macros defined-but-empty, which breaks every "#if _WIN32_WINNT >= ..."
# check in the Windows SDK headers. 0x0600 = Vista, matching upstream FDB.
set(WINDOWS_TARGET 0x0600)
# The same values as command-line defines - see the target_compile_definitions
# comment below for why config.h alone is not enough on Windows.
set(WINDOWS_TARGET_DEFS _WIN32_WINNT=${WINDOWS_TARGET} WINVER=${WINDOWS_TARGET} NTDDI_VERSION=0x06000000)
include(CheckSymbolExists)
check_symbol_exists(aligned_alloc "stdlib.h" HAS_ALIGNED_ALLOC)
configure_file(flow/ApiVersion.h.cmake "${CODEGEN_INCLUDE_DIR}/flow/ApiVersion.h")
configure_file(flow/SourceVersion.h.cmake "${CODEGEN_INCLUDE_DIR}/flow/SourceVersion.h")
configure_file(flow/config.h.cmake "${CODEGEN_INCLUDE_DIR}/flow/config.h")

# --- codegen: ProtocolVersion.h (Python + Jinja2) ---
set(PROTOCOL_VERSION_HEADER "${CODEGEN_INCLUDE_DIR}/flow/ProtocolVersion.h")
add_custom_command(
  OUTPUT "${PROTOCOL_VERSION_HEADER}"
  COMMAND ${Python3_EXECUTABLE}
          "${CMAKE_CURRENT_SOURCE_DIR}/flow/protocolversion/protocol_version.py"
          --source "${CMAKE_CURRENT_SOURCE_DIR}/flow/ProtocolVersions.cmake"
          --generator cpp
          --output "${PROTOCOL_VERSION_HEADER}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/flow/protocolversion/protocol_version.py"
          "${CMAKE_CURRENT_SOURCE_DIR}/flow/ProtocolVersions.cmake"
  COMMENT "Generating ProtocolVersion.h")
add_custom_target(ProtocolVersion DEPENDS "${PROTOCOL_VERSION_HEADER}")

# --- actor-compiler: transform .actor.cpp -> .g.cpp (our vendored Python port) ---
set(ACTORCOMPILER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/actorcompiler")
set(ACTOR_GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/actor-gen")
file(MAKE_DIRECTORY "${ACTOR_GEN_DIR}")

function(compile_actor_file actor_src out_var)
  get_filename_component(actor_name "${actor_src}" NAME_WE)
  set(generated "${ACTOR_GEN_DIR}/${actor_name}.g.cpp")
  add_custom_command(
    OUTPUT "${generated}"
    COMMAND ${Python3_EXECUTABLE} -m actorcompiler "${actor_src}" "${generated}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    DEPENDS "${actor_src}"
            "${ACTORCOMPILER_DIR}/__main__.py"
            "${ACTORCOMPILER_DIR}/actor_compiler.py"
            "${ACTORCOMPILER_DIR}/actor_parser.py"
            "${ACTORCOMPILER_DIR}/parse_tree.py"
            "${ACTORCOMPILER_DIR}/errors.py"
    COMMENT "actorcompiler: ${actor_name}.actor.cpp -> ${actor_name}.g.cpp")
  set(${out_var} "${generated}" PARENT_SCOPE)
endfunction()

compile_actor_file("${CMAKE_CURRENT_SOURCE_DIR}/flow/ActorCollection.actor.cpp" ACTOR_COLLECTION_GEN)
compile_actor_file("${CMAKE_CURRENT_SOURCE_DIR}/flow/genericactors.actor.cpp" GENERIC_ACTORS_GEN)

# genericactors.actor.h (a header, not a .cpp) has its own raw ACTOR/state/choose
# syntax; anything compiled with POST_ACTOR_COMPILER set (i.e. every actor-
# generated .g.cpp above) needs the transformed flow/genericactors.actor.g.h
# this header's own #include falls back to, or the untransformed syntax fails
# to parse - actorcompiler.h's IDE-only fallback macros are deliberately
# suppressed whenever POST_ACTOR_COMPILER is set.
set(GENERICACTORS_H_GEN_DIR "${ACTOR_GEN_DIR}/include/flow")
file(MAKE_DIRECTORY "${GENERICACTORS_H_GEN_DIR}")
set(GENERICACTORS_H_GEN "${GENERICACTORS_H_GEN_DIR}/genericactors.actor.g.h")
add_custom_command(
  OUTPUT "${GENERICACTORS_H_GEN}"
  COMMAND ${Python3_EXECUTABLE} -m actorcompiler
          "${CMAKE_CURRENT_SOURCE_DIR}/flow/include/flow/genericactors.actor.h" "${GENERICACTORS_H_GEN}"
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/flow/include/flow/genericactors.actor.h"
          "${ACTORCOMPILER_DIR}/__main__.py"
          "${ACTORCOMPILER_DIR}/actor_compiler.py"
          "${ACTORCOMPILER_DIR}/actor_parser.py"
          "${ACTORCOMPILER_DIR}/parse_tree.py"
          "${ACTORCOMPILER_DIR}/errors.py"
  COMMENT "actorcompiler: genericactors.actor.h -> genericactors.actor.g.h")
add_custom_target(GenericActorsHeader DEPENDS "${GENERICACTORS_H_GEN}")

# --- flow library sources (plain .cpp, actor-generated files added separately) ---
file(GLOB FLOW_SRCS CONFIGURE_DEPENDS "flow/*.cpp")
list(REMOVE_ITEM FLOW_SRCS
  "${CMAKE_CURRENT_SOURCE_DIR}/flow/ActorCollection.actor.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/flow/genericactors.actor.cpp")
list(APPEND FLOW_SRCS "${ACTOR_COLLECTION_GEN}" "${GENERIC_ACTORS_GEN}")

if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64")
  list(APPEND FLOW_SRCS flow/aarch64/memcmp.S flow/aarch64/memcpy.S)
endif()

add_library(flow STATIC ${FLOW_SRCS})
if(WIN32 AND CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  # clang's optimizer segfaults (ICE in the jump-threading pass) on the
  # UDPSocket::connect coroutine in Net2.cpp: clang 22 at /O2, clang 20 (the
  # GitHub runner's LLVM) even at /O1. Compile just this TU at /Od - the later
  # option wins in cl-style command lines, so appending is enough.
  set_source_files_properties(flow/Net2.cpp PROPERTIES COMPILE_OPTIONS "/Od")
endif()
add_dependencies(flow ProtocolVersion GenericActorsHeader)

target_include_directories(flow PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/flow/include"
  "${CODEGEN_INCLUDE_DIR}"
  "${ACTOR_GEN_DIR}/include"
  PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/flow")

# genericactors.actor.h's raw ACTOR/state/choose syntax only compiles two
# ways: actorcompiler.h's IDE-only no-op macros (raw source, no
# POST_ACTOR_COMPILER), or the actor-compiler-generated genericactors.actor.g.h
# above (real build). NO_INTELLISENSE selects the latter unconditionally, so
# every flow consumer - not just the two actor-generated .g.cpp files that
# define POST_ACTOR_COMPILER themselves - gets the same, real, transformed code.
target_compile_definitions(flow PUBLIC NO_INTELLISENSE)

target_link_libraries(flow
  PUBLIC boost_target OpenSSL::SSL fmt::fmt Threads::Threads SimpleOpt crc32 libb64
  PRIVATE stacktrace)

if(UNIX AND NOT APPLE)
  target_link_libraries(flow PRIVATE folly_memcpy)
  target_compile_definitions(flow PRIVATE WITH_FOLLY_MEMCPY)
endif()

if(WIN32)
  target_link_libraries(flow PUBLIC winmm.lib psapi.lib)
elseif(NOT APPLE)
  target_link_libraries(flow PUBLIC rt)
endif()

if(APPLE)
  find_library(IO_KIT IOKit)
  find_library(CORE_FOUNDATION CoreFoundation)
  target_link_libraries(flow PUBLIC ${IO_KIT} ${CORE_FOUNDATION})
endif()

target_compile_definitions(flow PUBLIC BOOST_ERROR_CODE_HEADER_ONLY BOOST_SYSTEM_NO_DEPRECATED)
if(WIN32)
  # MSVC's <cmath> only exposes M_E/M_PI/etc. when this is defined before the
  # first inclusion; a header-level #define is unreliable since fmt or Boost
  # headers can pull in <cmath> before flow's own headers are ever reached.
  #
  # _WIN32_WINNT must come from the command line, not flow/config.h: TUs like
  # Net2.cpp include boost/asio headers *before* any flow header, and Boost.Asio
  # self-defaults _WIN32_WINNT (to 0x0601) when unset. flow/config.h sets 0x0600
  # for TUs that include flow first (e.g. IThreadPool.cpp), so the same asio
  # inline code gets instantiated under two different Windows targets, and the
  # linker folds the incompatible copies - at runtime the io_context service
  # registry then rejects its own services with "Invalid service owner".
  target_compile_definitions(flow PUBLIC _USE_MATH_DEFINES ${WINDOWS_TARGET_DEFS})
endif()

# picoquic + picotls + mbedtls: standalone, not linked against `flow`.
# sockloop.c/winsockloop.c are excluded on every platform (see README) -
# picoquic never owns a real socket here.

set(PICOQUIC_DEFS
  PICOQUIC_WITH_MBEDTLS=1
  PTLS_WITHOUT_OPENSSL=1
  PTLS_WITHOUT_FUSION=1
  PICOQUIC_WITHOUT_SSLKEYLOG=1
  DISABLE_DEBUG_PRINTF=1
)
if(WIN32)
  list(APPEND PICOQUIC_DEFS _WINDOWS)
endif()

set(VENDOR_QUIC_INCLUDES
  thirdparty/picoquic/picoquic
  thirdparty/picoquic/picohttp
  thirdparty/picoquic/picoquic_mbedtls
  thirdparty/picoquic/loglib
  thirdparty/picotls/include
  thirdparty/picotls/deps/cifra/src
  thirdparty/picotls/deps/cifra/src/ext
  thirdparty/picotls/deps/micro-ecc
  thirdparty/mbedtls/include
)
if(WIN32)
  list(INSERT VENDOR_QUIC_INCLUDES 0 thirdparty/picotls/picotlsvs/picotls)
endif()

file(GLOB PICOQUIC_CORE_SRCS "thirdparty/picoquic/picoquic/*.c")
# Exclude on every platform, not just Windows: we never let picoquic drive
# its own sockets (see comment above).
list(REMOVE_ITEM PICOQUIC_CORE_SRCS
  "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picoquic/picoquic/sockloop.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picoquic/picoquic/winsockloop.c")

file(GLOB PICOHTTP_SRCS "thirdparty/picoquic/picohttp/*.c")

file(GLOB PICOTLS_SRCS "thirdparty/picotls/lib/*.c")
foreach(_ex certificate_compression.c fusion.c mbedtls.c mbedtls_sign.c openssl.c)
  list(REMOVE_ITEM PICOTLS_SRCS "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picotls/lib/${_ex}")
endforeach()
if(WIN32)
  # wincompat.h (included via the picotlsvs/picotls include dir above) #defines
  # gettimeofday to wintimeofday; without this TU, that symbol is never defined.
  list(APPEND PICOTLS_SRCS "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picotls/picotlsvs/picotls/wintimeofday.c")
endif()

file(GLOB PICOTLS_CIFRA_SRCS "thirdparty/picotls/lib/cifra/*.c")
list(REMOVE_ITEM PICOTLS_CIFRA_SRCS
  "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picotls/lib/cifra/libaegis.c")

file(GLOB CIFRA_SRCS "thirdparty/picotls/deps/cifra/src/*.c")
file(GLOB CIFRA_TEST_SRCS "thirdparty/picotls/deps/cifra/src/test*.c")
list(REMOVE_ITEM CIFRA_SRCS ${CIFRA_TEST_SRCS})
foreach(_ex donna naclref tweetnacl)
  list(REMOVE_ITEM CIFRA_SRCS
    "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picotls/deps/cifra/src/curve25519.${_ex}.c")
endforeach()

file(GLOB MICROECC_SRCS "thirdparty/picotls/deps/micro-ecc/*.c")
file(GLOB PICOQUIC_MBEDTLS_SRCS "thirdparty/picoquic/picoquic_mbedtls/*.c")

file(GLOB MBEDTLS_SRCS "thirdparty/mbedtls/library/*.c")
list(REMOVE_ITEM MBEDTLS_SRCS
  "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/mbedtls/library/godot_core_mbedtls_platform.c")

file(GLOB LOGLIB_SRCS "thirdparty/picoquic/loglib/*.c")

add_library(picoquic_vendored STATIC
  ${PICOQUIC_CORE_SRCS} ${PICOHTTP_SRCS}
  ${PICOTLS_SRCS} ${PICOTLS_CIFRA_SRCS} ${CIFRA_SRCS} ${MICROECC_SRCS}
  ${PICOQUIC_MBEDTLS_SRCS} ${MBEDTLS_SRCS} ${LOGLIB_SRCS})
target_compile_options(picoquic_vendored PRIVATE -w)
# Real cl.exe (CMAKE_CXX_COMPILER_ID "MSVC") doesn't understand GNU-style
# -Wno-error= flags; clang-cl (CMAKE_CXX_COMPILER_ID "Clang", MSVC ABI) does.
if(WIN32 AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "MSVC"))
  target_compile_options(picoquic_vendored PRIVATE
    -Wno-error=incompatible-pointer-types
    -Wno-error=implicit-function-declaration
    -Wno-error=int-conversion)
endif()
target_compile_definitions(picoquic_vendored PRIVATE ${PICOQUIC_DEFS})
target_include_directories(picoquic_vendored SYSTEM PRIVATE ${VENDOR_QUIC_INCLUDES})
target_link_libraries(picoquic_vendored PUBLIC Threads::Threads)
if(WIN32)
  target_link_libraries(picoquic_vendored PUBLIC ws2_32 iphlpapi bcrypt)
endif()

add_executable(picoquic_vendor_test examples/picoquic_vendor_test.c)
target_compile_definitions(picoquic_vendor_test PRIVATE ${PICOQUIC_DEFS})
target_include_directories(picoquic_vendor_test SYSTEM PRIVATE ${VENDOR_QUIC_INCLUDES})
target_link_libraries(picoquic_vendor_test PRIVATE picoquic_vendored)

# --- picoquicdemo_client: the vendored stack as a real HTTP/3 client against
# an independent, external, live server - not the Flow-driven fanout relay.
# Unlike picoquic_vendored (which never owns a real socket, so Flow's
# simulator stays in control - see the comment above VENDOR_QUIC_INCLUDES),
# this target genuinely owns its own sockets via picoquic's own packet loop:
# it is a standalone devtool, not on Flow's determinism-critical path, so
# picoquic driving real I/O here is the correct shape, not a violation of it.
# picoquicdemo.c/getopt.c/demoserver.c/sockloop.c/winsockloop.c are the
# vendored reference CLI client+packet-loop this repo does not otherwise
# build; verified locally against a live external HTTP/3 server (real TLS
# 1.3 handshake, real CA chain validation via certs/mozilla-cacert.pem,
# real response body) before wiring in here.
file(GLOB PICOQUICDEMO_EXTRA_SRCS
  "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picoquic/picoquic/sockloop.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picoquic/picohttp/demoserver.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picoquic/picoquicfirst/picoquicdemo.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picoquic/picoquicfirst/getopt.c")
if(WIN32)
  list(APPEND PICOQUICDEMO_EXTRA_SRCS
    "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picoquic/picoquic/winsockloop.c")
endif()
add_executable(picoquicdemo_client ${PICOQUICDEMO_EXTRA_SRCS})
target_compile_definitions(picoquicdemo_client PRIVATE ${PICOQUIC_DEFS})
target_include_directories(picoquicdemo_client SYSTEM PRIVATE ${VENDOR_QUIC_INCLUDES}
  "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picoquic/picoquicfirst")
if(WIN32 AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "MSVC"))
  target_compile_options(picoquicdemo_client PRIVATE
    /FIstdlib.h /FImalloc.h /FIWinsock2.h /FIws2tcpip.h
    -Wno-error=incompatible-pointer-types
    -Wno-error=implicit-function-declaration
    -Wno-error=int-conversion)
endif()
target_link_libraries(picoquicdemo_client PRIVATE picoquic_vendored)

# --- artifacts_mmo_h3_client: the vendored stack as a real AUTHENTICATED
# HTTP/3 client - the gap picoquicdemo_client's scenario mechanism can't
# fill (h3zero_client_create_stream_request_ex only ever encodes the
# spec-required pseudo-headers, no custom "authorization" header; the same
# gap found this session in v-sekai-multiplayer-fabric/fabric-godot-core's
# http3_client.cpp, whose request()'s p_headers parameter is accepted but
# stubbed out). artifacts_mmo_h3_client.c is new code, not a vendored file:
# it reuses picoquic_create/_create_cnx/_start_client_cnx and (unmodified)
# picoquic_demo_client_callback for receiving, and adds one new function,
# build_authenticated_request(), that mirrors
# h3zero_client_create_stream_request_ex's frame assembly with one extra
# QPACK literal-name field (h3zero_qpack_literal_plus_name_encode, already
# used elsewhere in h3zero.c for headers with no static-table entry) for
# "authorization", plus a real JSON body embedded as a DATA frame for POST
# actions. Verified locally against the live ArtifactsMMO API: authenticated
# GET /characters/{name} and POST .../action/gathering (a real game action,
# real cooldown, real inventory update) both round-tripped correctly.
add_executable(artifacts_mmo_h3_client examples/artifacts_mmo_h3_client.c)
target_compile_definitions(artifacts_mmo_h3_client PRIVATE ${PICOQUIC_DEFS})
target_include_directories(artifacts_mmo_h3_client SYSTEM PRIVATE ${VENDOR_QUIC_INCLUDES}
  "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/picoquic/picoquicfirst")
if(WIN32 AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "MSVC"))
  target_compile_options(artifacts_mmo_h3_client PRIVATE
    /FIstdlib.h /FImalloc.h /FIWinsock2.h /FIws2tcpip.h
    -Wno-error=incompatible-pointer-types
    -Wno-error=implicit-function-declaration
    -Wno-error=int-conversion)
endif()
target_link_libraries(artifacts_mmo_h3_client PRIVATE picoquic_vendored)

# --- libriscv: the RISC-V sandbox substrate for ADR 0006's scripted-content
# tier (docs/decisions/0006-libriscv-sandboxed-s7-lisp-over-native-janet.md).
# RISCV_BINARY_TRANSLATION is off: it shells out to a system C compiler
# at guest-load time to JIT-translate hot guest code, which is unneeded for
# proving the vendored interpreter itself and is extra attack surface for a
# sandbox whose whole point is a closed, host-controlled execution boundary.
# RISCV_BRK_MEMORY_SIZE is bumped from the 1MB default: s7_init() alone
# needs more heap than that (found the hard way - an unpatched 1MB limit
# made malloc return NULL partway through init, s7 doesn't check, and the
# guest hit a protection fault dereferencing it).
set(RISCV_32I OFF CACHE BOOL "" FORCE)
set(RISCV_64I ON CACHE BOOL "" FORCE)
set(RISCV_BINARY_TRANSLATION OFF CACHE BOOL "" FORCE)
add_subdirectory(thirdparty/libriscv/lib)
target_compile_definitions(riscv PUBLIC RISCV_BRK_MEMORY_SIZE=134217728ull)
if(WIN32)
  # windows.h's min/max macros shadow std::min/std::max in
  # thirdparty/libriscv/lib/libriscv/win32/system_calls.cpp; upstream
  # expects the consumer to opt out of them.
  target_compile_definitions(riscv PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

add_executable(libriscv_vendor_test examples/libriscv_vendor_test.cpp)
target_compile_definitions(libriscv_vendor_test PRIVATE
  LIBRISCV_VENDOR_TEST_GUEST_ELF="${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/libriscv/examples/embed/fib.rv64.elf")
target_link_libraries(libriscv_vendor_test PRIVATE riscv)

# --- ir_compiled_content_test: checkpoint 4 of ADR 0013/0014's compiler -
# loads a Lean4-compiled-to-RISC-V function (fanout-core/IrCodegenScratch.lean,
# checkpoint 3) linked into a minimal freestanding ELF (no libc - see that
# script's own header comment for the exact build recipe) and proves the
# same determinism property ADR 0006 already established for the
# interpreted s7 guest: two independent Machine instances given the
# identical vmcall produce byte-identical instruction counts. The ELF
# itself is not built by this CMake project (needs Lean4 + the separate
# RISC-V toolchain, same reasoning as s7_guest.elf above); its path is
# supplied as a compile definition, expected to already exist.
add_executable(ir_compiled_content_test examples/ir_compiled_content_test.cpp)
target_compile_definitions(ir_compiled_content_test PRIVATE
  IR_COMPILED_CONTENT_TEST_GUEST_ELF="${CMAKE_CURRENT_SOURCE_DIR}/fanout-core/IrCodegenScratch_out.elf")
target_link_libraries(ir_compiled_content_test PRIVATE riscv)

# --- s7_riscv_eval_int_test: checkpoint 1 of the "real content through the
# interpreted s7 path" plan (ADR 0028) - verifies guest_eval_int returns a
# real usable integer via the register, not just stdout text a human has to
# read. Standalone (no Flow actor), same reasoning as ir_compiled_content_test.
add_executable(s7_riscv_eval_int_test
  examples/s7_riscv_eval_int_test.cpp
  examples/s7_riscv_core.cpp)
target_include_directories(s7_riscv_eval_int_test PRIVATE examples)
target_link_libraries(s7_riscv_eval_int_test PRIVATE riscv)

# --- s7_riscv_loot_golden_test: checkpoint 3 of the "real content through
# interpreted s7" plan (ADR 0028) - loads riscv-guests/content/loot.scm
# (hand-ported from v-sekai-multiplayer-fabric/loot) into two independent
# Machine instances and checks both agree with each other AND with the
# Lean4 reference value (computed once against upstream, not kept as a
# live file in this repo - ADR 0032).
add_executable(s7_riscv_loot_golden_test
  examples/s7_riscv_loot_golden_test.cpp
  examples/s7_riscv_core.cpp)
target_include_directories(s7_riscv_loot_golden_test PRIVATE examples)
target_link_libraries(s7_riscv_loot_golden_test PRIVATE riscv)

# --- s7_riscv_combat_golden_test: golden-vector proof for
# riscv-guests/content/combat.scm, same methodology as
# s7_riscv_loot_golden_test above.
add_executable(s7_riscv_combat_golden_test
  examples/s7_riscv_combat_golden_test.cpp
  examples/s7_riscv_core.cpp)
target_include_directories(s7_riscv_combat_golden_test PRIVATE examples)
target_link_libraries(s7_riscv_combat_golden_test PRIVATE riscv)

# --- s7_riscv_progression_golden_test: golden-vector proof for
# riscv-guests/content/progression.scm, same methodology as the loot/combat
# golden tests above.
add_executable(s7_riscv_progression_golden_test
  examples/s7_riscv_progression_golden_test.cpp
  examples/s7_riscv_core.cpp)
target_include_directories(s7_riscv_progression_golden_test PRIVATE examples)
target_link_libraries(s7_riscv_progression_golden_test PRIVATE riscv)

# --- s7_riscv_macro_test: verifies riscv-guests/content/record-macros.scm's
# define-record/record-with macros in isolation before combat.scm depends on
# them.
add_executable(s7_riscv_macro_test
  examples/s7_riscv_macro_test.cpp
  examples/s7_riscv_core.cpp)
target_include_directories(s7_riscv_macro_test PRIVATE examples)
target_link_libraries(s7_riscv_macro_test PRIVATE riscv)

# --- s7_riscv_taskweft_lite_golden_test: golden-vector proof for
# taskweft-lite.shrub's find-plan (HTN forward-decomposition core), against
# this repo's own real plan/bootstrap-domain.json content.
add_executable(s7_riscv_taskweft_lite_golden_test
  examples/s7_riscv_taskweft_lite_golden_test.cpp
  examples/s7_riscv_core.cpp)
target_include_directories(s7_riscv_taskweft_lite_golden_test PRIVATE examples)
target_link_libraries(s7_riscv_taskweft_lite_golden_test PRIVATE riscv)

# --- s7_riscv_taskweft_types_test: Layer 0 of the full taskweft port -
# verifies taskweft-types.shrub's allocNodeId/addToBlacklist/pruneNode.
add_executable(s7_riscv_taskweft_types_test
  examples/s7_riscv_taskweft_types_test.cpp
  examples/s7_riscv_core.cpp)
target_include_directories(s7_riscv_taskweft_types_test PRIVATE examples)
target_link_libraries(s7_riscv_taskweft_types_test PRIVATE riscv)

# --- s7_riscv_taskweft_commands_test: Layer 1 (part) of the taskweft port -
# verifies taskweft-commands.shrub.
add_executable(s7_riscv_taskweft_commands_test
  examples/s7_riscv_taskweft_commands_test.cpp
  examples/s7_riscv_core.cpp)
target_include_directories(s7_riscv_taskweft_commands_test PRIVATE examples)
target_link_libraries(s7_riscv_taskweft_commands_test PRIVATE riscv)

# --- s7_riscv_shrubbery_reader_test: verifies shrubbery-to-scheme.scm (the
# s7 port of the shrubbery reader) against shrubbery_to_scheme.py's own
# known-good output on the same input.
add_executable(s7_riscv_shrubbery_reader_test
  examples/s7_riscv_shrubbery_reader_test.cpp
  examples/s7_riscv_core.cpp)
target_include_directories(s7_riscv_shrubbery_reader_test PRIVATE examples)
target_link_libraries(s7_riscv_shrubbery_reader_test PRIVATE riscv)

# --- s7_riscv_actor_test: a real Flow actor (s7_riscv_actor.actor.cpp)
# calling into the libriscv-sandboxed s7 guest (riscv-guests/s7_guest.elf,
# built from riscv-guests/s7_guest_main.c - see riscv-guests/README.md for
# the newlib cross-compile recipe; not built by this CMake project, since
# it needs a separate RISC-V toolchain this build doesn't otherwise
# require). Proves ADR 0006's scripting tier actually composes with
# Flow's actor scheduling and replays deterministically: two independent
# libriscv Machine instances, driven through the same actor, cost the
# identical total instruction count for the identical call sequence.
compile_actor_file("${CMAKE_CURRENT_SOURCE_DIR}/examples/s7_riscv_actor.actor.cpp" S7_RISCV_ACTOR_GEN)
add_executable(s7_riscv_actor_test
  examples/s7_riscv_actor_test.cpp
  examples/s7_riscv_core.cpp
  "${S7_RISCV_ACTOR_GEN}")
target_include_directories(s7_riscv_actor_test PRIVATE examples)
target_link_libraries(s7_riscv_actor_test PRIVATE flow riscv)

# --- fanout-core: Lean4 kernel (slot map + subscriber dispatch), compiled to a
# static library via the Lean toolchain's own bundled clang/llvm-ar - the
# generated C relies on Lean-specific attributes, so it's built with the same
# compiler that emitted it rather than the project's own CXX toolchain.

find_program(LAKE_EXECUTABLE lake REQUIRED)
find_program(LEAN_EXECUTABLE lean REQUIRED)

execute_process(
  COMMAND "${LEAN_EXECUTABLE}" --print-prefix
  # elan resolves which toolchain "lean" means from the lean-toolchain file
  # in the current directory; run from fanout-core/ (where that file lives)
  # or elan has nothing to resolve against and silently prints an error to
  # stderr while leaving LEAN_PREFIX empty.
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/fanout-core"
  OUTPUT_VARIABLE LEAN_PREFIX
  OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE LEAN_PRINT_PREFIX_RESULT)
if(NOT LEAN_PRINT_PREFIX_RESULT EQUAL 0 OR LEAN_PREFIX STREQUAL "")
  message(FATAL_ERROR "lean --print-prefix failed or returned an empty prefix (exit ${LEAN_PRINT_PREFIX_RESULT})")
endif()

if(WIN32)
  set(LEAN_CLANG "${LEAN_PREFIX}/bin/clang.exe")
  set(LEAN_AR "${LEAN_PREFIX}/bin/llvm-ar.exe")
  set(LEAN_RUNTIME_LIBS
    "${LEAN_PREFIX}/lib/lean/libleanshared.dll.a"
    "${LEAN_PREFIX}/lib/lean/libInit_shared.dll.a")
else()
  set(LEAN_CLANG "${LEAN_PREFIX}/bin/clang")
  set(LEAN_AR "${LEAN_PREFIX}/bin/llvm-ar")
  set(LEAN_RUNTIME_LIBS
    "${LEAN_PREFIX}/lib/lean/libleanshared${CMAKE_SHARED_LIBRARY_SUFFIX}"
    "${LEAN_PREFIX}/lib/lean/libInit_shared${CMAKE_SHARED_LIBRARY_SUFFIX}")
endif()

set(LEAN_CLANG_SYSROOT_FLAGS)
if(APPLE)
  # Lean's bundled clang has no Apple SDK of its own; point it at Xcode's,
  # or system headers like stdio.h don't resolve.
  execute_process(
    COMMAND xcrun --show-sdk-path
    OUTPUT_VARIABLE LEAN_CLANG_SDK_PATH
    OUTPUT_STRIP_TRAILING_WHITESPACE)
  set(LEAN_CLANG_SYSROOT_FLAGS -isysroot "${LEAN_CLANG_SDK_PATH}")
endif()

set(FANOUT_CORE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/fanout-core")
set(FANOUT_CORE_IR_DIR "${FANOUT_CORE_DIR}/.lake/build/ir")
set(FANOUT_CORE_GEN_C
  "${FANOUT_CORE_IR_DIR}/Fanoutcore.c"
  "${FANOUT_CORE_IR_DIR}/Fanoutcore/SlotMap.c"
  "${FANOUT_CORE_IR_DIR}/Fanoutcore/FanoutCore.c"
  "${FANOUT_CORE_IR_DIR}/Fanoutcore/Zone.c"
  "${FANOUT_CORE_IR_DIR}/Fanoutcore/Partition.c"
  "${FANOUT_CORE_IR_DIR}/Fanoutcore/ZoneDispatch.c"
  "${FANOUT_CORE_IR_DIR}/Fanoutcore/Ffi.c")
file(GLOB FANOUT_CORE_LEAN_SRCS CONFIGURE_DEPENDS
  "${FANOUT_CORE_DIR}/*.lean" "${FANOUT_CORE_DIR}/Fanoutcore/*.lean")

add_custom_command(
  OUTPUT ${FANOUT_CORE_GEN_C}
  COMMAND "${LAKE_EXECUTABLE}" build Fanoutcore
  WORKING_DIRECTORY "${FANOUT_CORE_DIR}"
  DEPENDS ${FANOUT_CORE_LEAN_SRCS}
          "${FANOUT_CORE_DIR}/lakefile.toml"
          "${FANOUT_CORE_DIR}/lean-toolchain"
  COMMENT "lake build Fanoutcore")

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/fanout-core-obj")

set(FANOUT_CORE_OBJS)
foreach(_src ${FANOUT_CORE_GEN_C})
  file(RELATIVE_PATH _rel "${FANOUT_CORE_IR_DIR}" "${_src}")
  # Flatten the relative path into a unique object-file name: NAME_WE alone
  # collides case-insensitively on Windows ("Fanoutcore.c" root module vs.
  # "Fanoutcore/FanoutCore.c"), silently dropping one object from the archive.
  string(REGEX REPLACE "\\.c$" "" _rel_we "${_rel}")
  string(REPLACE "/" "_" _name "${_rel_we}")
  set(_obj "${CMAKE_CURRENT_BINARY_DIR}/fanout-core-obj/${_name}.o")
  add_custom_command(
    OUTPUT "${_obj}"
    COMMAND "${LEAN_CLANG}" -std=c11 -O2 ${LEAN_CLANG_SYSROOT_FLAGS} -I "${LEAN_PREFIX}/include" -I "${LEAN_PREFIX}/include/clang" -c "${_src}" -o "${_obj}"
    DEPENDS ${FANOUT_CORE_GEN_C}
    COMMENT "clang (lean toolchain): ${_rel} -> ${_name}.o")
  list(APPEND FANOUT_CORE_OBJS "${_obj}")
endforeach()

set(FANOUT_CORE_LIB "${CMAKE_CURRENT_BINARY_DIR}/fanout-core-obj/libfanoutcore.a")
add_custom_command(
  OUTPUT "${FANOUT_CORE_LIB}"
  COMMAND "${LEAN_AR}" rcs "${FANOUT_CORE_LIB}" ${FANOUT_CORE_OBJS}
  DEPENDS ${FANOUT_CORE_OBJS}
  COMMENT "llvm-ar (lean toolchain): libfanoutcore.a")
add_custom_target(fanoutcore_build DEPENDS "${FANOUT_CORE_LIB}")

add_library(fanoutcore_lean STATIC IMPORTED GLOBAL)
set_target_properties(fanoutcore_lean PROPERTIES IMPORTED_LOCATION "${FANOUT_CORE_LIB}")
add_dependencies(fanoutcore_lean fanoutcore_build)
target_include_directories(fanoutcore_lean INTERFACE "${LEAN_PREFIX}/include")
target_link_libraries(fanoutcore_lean INTERFACE ${LEAN_RUNTIME_LIBS})

# --- sketch-core: Lean4 kernel (CSP1 codec + curve fit + sketch graph),
# built the same way as fanout-core: lake emits C, Lean's own clang/llvm-ar
# compile and archive it.
set(SKETCH_CORE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/sketch-core")
set(SKETCH_CORE_IR_DIR "${SKETCH_CORE_DIR}/.lake/build/ir")
set(SKETCH_CORE_GEN_C
  "${SKETCH_CORE_IR_DIR}/SketchCore.c"
  "${SKETCH_CORE_IR_DIR}/SketchCore/Vec3.c"
  "${SKETCH_CORE_IR_DIR}/SketchCore/Codec.c"
  "${SKETCH_CORE_IR_DIR}/SketchCore/Fit.c"
  "${SKETCH_CORE_IR_DIR}/SketchCore/Graph.c"
  "${SKETCH_CORE_IR_DIR}/SketchCore/History.c"
  "${SKETCH_CORE_IR_DIR}/SketchCore/Ffi.c")
file(GLOB SKETCH_CORE_LEAN_SRCS CONFIGURE_DEPENDS
  "${SKETCH_CORE_DIR}/*.lean" "${SKETCH_CORE_DIR}/SketchCore/*.lean")

add_custom_command(
  OUTPUT ${SKETCH_CORE_GEN_C}
  COMMAND "${LAKE_EXECUTABLE}" build SketchCore
  WORKING_DIRECTORY "${SKETCH_CORE_DIR}"
  DEPENDS ${SKETCH_CORE_LEAN_SRCS}
          "${SKETCH_CORE_DIR}/lakefile.toml"
          "${SKETCH_CORE_DIR}/lean-toolchain"
  COMMENT "lake build SketchCore")

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/sketch-core-obj")

set(SKETCH_CORE_OBJS)
foreach(_src ${SKETCH_CORE_GEN_C})
  file(RELATIVE_PATH _rel "${SKETCH_CORE_IR_DIR}" "${_src}")
  string(REGEX REPLACE "\\.c$" "" _rel_we "${_rel}")
  string(REPLACE "/" "_" _name "${_rel_we}")
  set(_obj "${CMAKE_CURRENT_BINARY_DIR}/sketch-core-obj/${_name}.o")
  add_custom_command(
    OUTPUT "${_obj}"
    COMMAND "${LEAN_CLANG}" -std=c11 -O2 ${LEAN_CLANG_SYSROOT_FLAGS} -I "${LEAN_PREFIX}/include" -I "${LEAN_PREFIX}/include/clang" -c "${_src}" -o "${_obj}"
    DEPENDS ${SKETCH_CORE_GEN_C}
    COMMENT "clang (lean toolchain): ${_rel} -> ${_name}.o")
  list(APPEND SKETCH_CORE_OBJS "${_obj}")
endforeach()

set(SKETCH_CORE_LIB "${CMAKE_CURRENT_BINARY_DIR}/sketch-core-obj/libsketchcore.a")
add_custom_command(
  OUTPUT "${SKETCH_CORE_LIB}"
  COMMAND "${LEAN_AR}" rcs "${SKETCH_CORE_LIB}" ${SKETCH_CORE_OBJS}
  DEPENDS ${SKETCH_CORE_OBJS}
  COMMENT "llvm-ar (lean toolchain): libsketchcore.a")
add_custom_target(sketchcore_build DEPENDS "${SKETCH_CORE_LIB}")

add_library(sketchcore_lean STATIC IMPORTED GLOBAL)
set_target_properties(sketchcore_lean PROPERTIES IMPORTED_LOCATION "${SKETCH_CORE_LIB}")
add_dependencies(sketchcore_lean sketchcore_build)
target_include_directories(sketchcore_lean INTERFACE "${LEAN_PREFIX}/include")
target_link_libraries(sketchcore_lean INTERFACE ${LEAN_RUNTIME_LIBS})

# --- picoquic_fanout_server: the Flow-driven bridge actor ---
compile_actor_file("${CMAKE_CURRENT_SOURCE_DIR}/examples/picoquic_fanout_server.actor.cpp" FANOUT_SERVER_GEN)
compile_actor_file("${CMAKE_CURRENT_SOURCE_DIR}/examples/fanout_server_main.actor.cpp" FANOUT_SERVER_MAIN_GEN)

add_executable(picoquic_fanout_server
  ${FANOUT_SERVER_GEN}
  examples/fanout_core_ffi.cpp
  examples/sketch_core_ffi.cpp
  ${FANOUT_SERVER_MAIN_GEN})
target_compile_definitions(picoquic_fanout_server PRIVATE ${PICOQUIC_DEFS})
target_include_directories(picoquic_fanout_server PRIVATE examples)
target_include_directories(picoquic_fanout_server SYSTEM PRIVATE ${VENDOR_QUIC_INCLUDES})
target_link_libraries(picoquic_fanout_server PRIVATE flow picoquic_vendored fanoutcore_lean sketchcore_lean)
if(WIN32)
  target_link_libraries(picoquic_fanout_server PRIVATE ws2_32)
endif()

# --- fanout_load_client: a Flow-actor QUIC load driver against picoquic_fanout_server ---
compile_actor_file("${CMAKE_CURRENT_SOURCE_DIR}/examples/fanout_load_client.actor.cpp" FANOUT_LOAD_CLIENT_GEN)
compile_actor_file("${CMAKE_CURRENT_SOURCE_DIR}/examples/fanout_load_client_main.actor.cpp" FANOUT_LOAD_CLIENT_MAIN_GEN)

add_executable(fanout_load_client
  ${FANOUT_LOAD_CLIENT_GEN}
  ${FANOUT_LOAD_CLIENT_MAIN_GEN})
target_compile_definitions(fanout_load_client PRIVATE ${PICOQUIC_DEFS})
target_include_directories(fanout_load_client SYSTEM PRIVATE ${VENDOR_QUIC_INCLUDES})
target_link_libraries(fanout_load_client PRIVATE flow picoquic_vendored)
if(WIN32)
  target_link_libraries(fanout_load_client PRIVATE ws2_32)
endif()
