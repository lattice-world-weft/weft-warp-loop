#include <lean/lean.h>
#include <stdio.h>
#include <stdint.h>

extern void lean_initialize_runtime_module(void);
extern lean_object *initialize_fanoutcore_Fanoutcore(uint8_t builtin);

/* IO Unit / IO UInt64 / IO (Array UInt64) exported functions return a
 * `lean_io_result` object (ok/error tagged); Lean4 erases the IO world
 * token at compile time for these signatures, so there is no explicit
 * world argument here. */
extern lean_object *fanout_init(uint32_t capacity);
extern lean_object *fanout_alloc_room(void);
extern lean_object *fanout_sub(uint64_t room_id, uint64_t conn_id);
extern lean_object *fanout_pub_targets(uint64_t room_id, uint64_t publisher_conn_id);
extern lean_object *fanout_free_room(uint64_t room_id);

static int check_io(lean_object *res, const char *step) {
	if (!lean_io_result_is_ok(res)) {
		fprintf(stderr, "FAIL %s: io error\n", step);
		lean_io_result_show_error(res);
		return 1;
	}
	return 0;
}

int main(void) {
	lean_initialize_runtime_module();
	lean_object *res = initialize_fanoutcore_Fanoutcore(1);
	if (!lean_io_result_is_ok(res)) {
		lean_io_result_show_error(res);
		return 1;
	}
	lean_dec_ref(res);
	lean_init_task_manager();
	lean_io_mark_end_initialization();

	int failures = 0;

	res = fanout_init(8);
	failures += check_io(res, "fanout_init");
	lean_dec_ref(res);

	res = fanout_alloc_room();
	failures += check_io(res, "fanout_alloc_room");
	uint64_t room_id = lean_unbox_uint64(lean_io_result_get_value(res));
	lean_dec_ref(res);
	printf("room_id = %llu\n", (unsigned long long)room_id);

	/* Three connections subscribe. */
	for (uint64_t conn = 1; conn <= 3; conn++) {
		res = fanout_sub(room_id, conn);
		failures += check_io(res, "fanout_sub");
		lean_dec_ref(res);
	}

	/* conn 1 publishes; targets should be {2, 3}, not 1. */
	res = fanout_pub_targets(room_id, 1);
	failures += check_io(res, "fanout_pub_targets");
	lean_object *arr = lean_io_result_get_value(res);
	size_t n = lean_array_size(arr);
	printf("targets (n=%zu):", n);
	int saw2 = 0, saw3 = 0, saw1 = 0;
	for (size_t i = 0; i < n; i++) {
		uint64_t v = lean_unbox_uint64(lean_array_get_core(arr, i));
		printf(" %llu", (unsigned long long)v);
		if (v == 1) saw1 = 1;
		if (v == 2) saw2 = 1;
		if (v == 3) saw3 = 1;
	}
	printf("\n");
	lean_dec_ref(res);

	if (n != 2 || !saw2 || !saw3 || saw1) {
		fprintf(stderr, "FAIL: expected targets {2,3}, got n=%zu saw1=%d saw2=%d saw3=%d\n",
				n, saw1, saw2, saw3);
		failures++;
	}

	/* A stale/unknown room id yields an empty target list, not a crash. */
	res = fanout_pub_targets(0xDEADBEEFULL << 32, 1);
	failures += check_io(res, "fanout_pub_targets(stale)");
	arr = lean_io_result_get_value(res);
	if (lean_array_size(arr) != 0) {
		fprintf(stderr, "FAIL: stale room id should yield zero targets\n");
		failures++;
	}
	lean_dec_ref(res);

	/* The core guarantee: free room_id, alloc a new room (which reuses
	 * the same array index with a bumped generation), then confirm the
	 * old room_id does NOT alias the new room. */
	res = fanout_free_room(room_id);
	failures += check_io(res, "fanout_free_room");
	lean_dec_ref(res);

	res = fanout_alloc_room();
	failures += check_io(res, "fanout_alloc_room (recycled)");
	uint64_t room_id2 = lean_unbox_uint64(lean_io_result_get_value(res));
	lean_dec_ref(res);
	printf("room_id2 = %llu (same index, bumped generation: %d)\n",
			(unsigned long long)room_id2, room_id2 != room_id);

	res = fanout_sub(room_id2, 99);
	failures += check_io(res, "fanout_sub (new room)");
	lean_dec_ref(res);

	res = fanout_pub_targets(room_id, 42);
	failures += check_io(res, "fanout_pub_targets(stale room_id)");
	arr = lean_io_result_get_value(res);
	if (lean_array_size(arr) != 0) {
		fprintf(stderr,
				"FAIL: stale room_id (freed, index recycled) must not alias "
				"the new room's subscribers\n");
		failures++;
	}
	lean_dec_ref(res);

	/* Capacity exceeded: a fresh core with room for exactly 2 rooms
	 * refuses a 3rd alloc (SENTINEL), rather than growing unboundedly
	 * or aliasing an existing room. */
	res = fanout_init(2);
	failures += check_io(res, "fanout_init(2)");
	lean_dec_ref(res);

	uint64_t cap_ids[2];
	for (int i = 0; i < 2; i++) {
		res = fanout_alloc_room();
		failures += check_io(res, "fanout_alloc_room(capacity test)");
		cap_ids[i] = lean_unbox_uint64(lean_io_result_get_value(res));
		lean_dec_ref(res);
	}
	res = fanout_alloc_room();
	failures += check_io(res, "fanout_alloc_room(over capacity)");
	uint64_t over_capacity = lean_unbox_uint64(lean_io_result_get_value(res));
	lean_dec_ref(res);
	if (over_capacity != 0xFFFFFFFFFFFFFFFFULL) {
		fprintf(stderr, "FAIL: allocating past capacity should return the SENTINEL, got %llu\n",
				(unsigned long long)over_capacity);
		failures++;
	}

	/* Double-free must not corrupt the freelist: freeing the same room
	 * id twice must not push its index onto the freelist twice (which
	 * would make two subsequent allocs both return the same index). */
	res = fanout_init(4);
	failures += check_io(res, "fanout_init(4)");
	lean_dec_ref(res);

	res = fanout_alloc_room();
	failures += check_io(res, "fanout_alloc_room(double-free test)");
	uint64_t df_id = lean_unbox_uint64(lean_io_result_get_value(res));
	lean_dec_ref(res);

	res = fanout_free_room(df_id);
	failures += check_io(res, "fanout_free_room(first)");
	lean_dec_ref(res);
	res = fanout_free_room(df_id); /* same id again: must be a no-op */
	failures += check_io(res, "fanout_free_room(double)");
	lean_dec_ref(res);

	res = fanout_alloc_room();
	failures += check_io(res, "fanout_alloc_room(post-double-free, 1st)");
	uint64_t reused1 = lean_unbox_uint64(lean_io_result_get_value(res));
	lean_dec_ref(res);
	res = fanout_alloc_room();
	failures += check_io(res, "fanout_alloc_room(post-double-free, 2nd)");
	uint64_t reused2 = lean_unbox_uint64(lean_io_result_get_value(res));
	lean_dec_ref(res);

	uint32_t idx1 = (uint32_t)(reused1 >> 32);
	uint32_t idx2 = (uint32_t)(reused2 >> 32);
	if (idx1 == idx2) {
		fprintf(stderr,
				"FAIL: double-free corrupted the freelist - two allocs both "
				"returned index %u instead of two distinct indices\n", idx1);
		failures++;
	}

	if (failures == 0) {
		printf("OK: all fanout-core FFI checks passed\n");
	}
	return failures == 0 ? 0 : 1;
}
