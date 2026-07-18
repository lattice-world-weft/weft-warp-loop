// SPDX-License-Identifier: MIT
// Copyright (c) 2026 K. S. Ernest (iFire) Lee

#include "fanout_core_ffi.h"

#include <cstdio>
#include <cstdlib>

// Second Lean package linked into the same process; its module initializer
// must run inside the same runtime-initialization window as fanoutcore's
// (before lean_io_mark_end_initialization), so it is registered here.
extern "C" lean_object* initialize_sketchcore_SketchCore(uint8_t builtin);
void sketchCoreShimInit(); // see sketch_core_ffi.cpp

void fanoutCoreInitialize(uint32_t roomCapacity) {
	lean_initialize_runtime_module();
	lean_object* res = initialize_fanoutcore_Fanoutcore(1);
	if (!lean_io_result_is_ok(res)) {
		lean_io_result_show_error(res);
		fprintf(stderr, "fanout-core: Lean module initialization failed\n");
		abort();
	}
	lean_dec_ref(res);
	sketchCoreShimInit();
	res = initialize_sketchcore_SketchCore(1);
	if (!lean_io_result_is_ok(res)) {
		lean_io_result_show_error(res);
		fprintf(stderr, "sketch-core: Lean module initialization failed\n");
		abort();
	}
	lean_dec_ref(res);
	lean_init_task_manager();
	lean_io_mark_end_initialization();

	res = fanout_init(roomCapacity);
	if (!lean_io_result_is_ok(res)) {
		lean_io_result_show_error(res);
		fprintf(stderr, "fanout-core: fanout_init failed\n");
		abort();
	}
	lean_dec_ref(res);
}
