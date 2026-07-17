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
