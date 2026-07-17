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
compile_actor_file("${CMAKE_CURRENT_SOURCE_DIR}/examples/hello_actor.actor.cpp" HELLO_ACTOR_GEN)

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
add_dependencies(flow ProtocolVersion)

target_include_directories(flow PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/flow/include"
  "${CODEGEN_INCLUDE_DIR}"
  PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/flow")

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

# --- minimal end-to-end smoke test: run one real actor via the real flow runtime ---
add_executable(hello_actor_test examples/main.cpp "${HELLO_ACTOR_GEN}")
target_link_libraries(hello_actor_test PRIVATE flow)

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
if(WIN32)
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
