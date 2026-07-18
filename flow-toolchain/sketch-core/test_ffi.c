/* Smoke test for sketch-core's C FFI: encode a CSP1 packet by hand, apply
 * it through the exports, verify dedup rejection, history replay, and that
 * a room's graph JSON is produced and deterministic. */
#include <lean/lean.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

extern void lean_initialize_runtime_module(void);
extern lean_object *initialize_sketchcore_SketchCore(uint8_t builtin);

/* IO-returning exports: lean_io_result-wrapped, world token erased. */
extern lean_object *sketch_reset(void);
extern lean_object *sketch_apply_packet(uint64_t room_id, lean_obj_arg bytes);
extern lean_object *sketch_history_count(uint64_t room_id);
extern lean_object *sketch_history_packet(uint64_t room_id, uint32_t i);
extern lean_object *sketch_graph_json(uint64_t room_id);

static int check_io(lean_object *res, const char *step) {
	if (!lean_io_result_is_ok(res)) {
		fprintf(stderr, "FAIL %s: io error\n", step);
		lean_io_result_show_error(res);
		return 1;
	}
	return 0;
}

static void put_u16le(uint8_t *p, uint16_t v) {
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
}

static void put_u32le(uint8_t *p, uint32_t v) {
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

static void put_f32le(uint8_t *p, float f) {
	uint32_t bits;
	memcpy(&bits, &f, 4);
	put_u32le(p, bits);
}

/* Build a CSP1 packet: closed unit square, 4 samples. */
static lean_object *make_square_packet(uint32_t peer, uint32_t stroke, uint16_t seq) {
	const uint16_t n = 4;
	const size_t size = 18 + (size_t)n * 16;
	lean_object *ba = lean_alloc_sarray(1, size, size);
	uint8_t *b = lean_sarray_cptr(ba);
	put_u32le(b + 0, 0x31505343u); /* 'CSP1' */
	put_u32le(b + 4, peer);
	put_u32le(b + 8, stroke);
	put_u16le(b + 12, seq);
	put_u16le(b + 14, n);
	b[16] = 1; /* closed */
	b[17] = 0; /* reserved */
	static const float pts[4][3] = {
		{ 0.f, 0.f, 0.f }, { 10.f, 0.f, 0.f }, { 10.f, 10.f, 0.f }, { 0.f, 10.f, 0.f }
	};
	for (int i = 0; i < 4; i++) {
		uint8_t *s = b + 18 + i * 16;
		put_f32le(s + 0, pts[i][0]);
		put_f32le(s + 4, pts[i][1]);
		put_f32le(s + 8, pts[i][2]);
		put_f32le(s + 12, 1.0f);
	}
	return ba;
}

int main(void) {
	lean_initialize_runtime_module();
	lean_object *res = initialize_sketchcore_SketchCore(1);
	if (!lean_io_result_is_ok(res)) {
		lean_io_result_show_error(res);
		return 1;
	}
	lean_dec_ref(res);
	lean_init_task_manager();
	lean_io_mark_end_initialization();

	int failures = 0;
	const uint64_t room = 42;

	res = sketch_reset();
	failures += check_io(res, "sketch_reset");
	lean_dec_ref(res);

	/* Apply a fresh packet: accepted (1). */
	res = sketch_apply_packet(room, make_square_packet(7, 1, 0));
	failures += check_io(res, "apply fresh");
	uint8_t accepted = lean_unbox(lean_io_result_get_value(res));
	lean_dec_ref(res);
	if (accepted != 1) {
		fprintf(stderr, "FAIL: fresh packet not accepted (%u)\n", accepted);
		failures++;
	}

	/* Same (peer,stroke,seq) again: rejected (0). */
	res = sketch_apply_packet(room, make_square_packet(7, 1, 0));
	failures += check_io(res, "apply dup");
	accepted = lean_unbox(lean_io_result_get_value(res));
	lean_dec_ref(res);
	if (accepted != 0) {
		fprintf(stderr, "FAIL: duplicate packet accepted\n");
		failures++;
	}

	/* Garbage bytes: rejected, no crash. */
	{
		lean_object *junk = lean_alloc_sarray(1, 5, 5);
		memcpy(lean_sarray_cptr(junk), "hello", 5);
		res = sketch_apply_packet(room, junk);
		failures += check_io(res, "apply junk");
		accepted = lean_unbox(lean_io_result_get_value(res));
		lean_dec_ref(res);
		if (accepted != 0) {
			fprintf(stderr, "FAIL: junk accepted\n");
			failures++;
		}
	}

	/* History holds exactly the one accepted packet, replayable. */
	res = sketch_history_count(room);
	failures += check_io(res, "history_count");
	uint32_t count = lean_unbox_uint32(lean_io_result_get_value(res));
	lean_dec_ref(res);
	if (count != 1) {
		fprintf(stderr, "FAIL: history count %u != 1\n", count);
		failures++;
	}
	res = sketch_history_packet(room, 0);
	failures += check_io(res, "history_packet");
	lean_object *stored = lean_io_result_get_value(res);
	if (lean_sarray_size(stored) != 18 + 4 * 16) {
		fprintf(stderr, "FAIL: stored packet size %zu\n", (size_t)lean_sarray_size(stored));
		failures++;
	}
	lean_dec_ref(res);

	/* Graph JSON: one closed square => exactly one cycle; and calling it
	 * twice yields byte-identical output (determinism). */
	res = sketch_graph_json(room);
	failures += check_io(res, "graph_json 1");
	lean_object *j1 = lean_io_result_get_value(res);
	const char *s1 = lean_string_cstr(j1);
	if (strstr(s1, "\"cycles\":1") == NULL) {
		fprintf(stderr, "FAIL: expected \"cycles\":1 in %s\n", s1);
		failures++;
	}
	res = sketch_graph_json(room);
	failures += check_io(res, "graph_json 2");
	const char *s2 = lean_string_cstr(lean_io_result_get_value(res));
	if (strcmp(s1, s2) != 0) {
		fprintf(stderr, "FAIL: graph json not deterministic\n");
		failures++;
	}

	if (failures == 0) {
		printf("OK: sketch-core FFI (accept, dedup, junk-reject, history, 1-cycle graph, deterministic)\n");
		return 0;
	}
	fprintf(stderr, "%d failure(s)\n", failures);
	return 1;
}
