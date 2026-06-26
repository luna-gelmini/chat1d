#include <stdio.h>
#include <assert.h>

#include "chat1_ffi.h"

static int tests_run = 0;
static int tests_passed = 0;

#define RUN(name) do { \
    printf("  %s ... ", #name); \
    chat1_sub_table_init(); \
    name(); \
    printf("ok\n"); \
    tests_passed++; \
    tests_run++; \
} while(0)

static void test_add_and_list(void) {
    uint64_t out[8];
    uint32_t count;
    assert(chat1_sub_add(100, 1) == CHAT1_SUB_OK);
    assert(chat1_sub_add(100, 2) == CHAT1_SUB_OK);
    assert(chat1_sub_list(100, out, 8, &count) == CHAT1_SUB_OK);
    assert(count == 2);
    assert(out[0] == 1);
    assert(out[1] == 2);
}

static void test_duplicate(void) {
    assert(chat1_sub_add(100, 1) == CHAT1_SUB_OK);
    assert(chat1_sub_add(100, 1) == CHAT1_SUB_ERR_DUPLICATE);
}

static void test_remove(void) {
    uint64_t out[8];
    uint32_t count;
    chat1_sub_add(100, 1);
    chat1_sub_add(100, 2);
    chat1_sub_add(100, 3);
    assert(chat1_sub_remove(100, 2) == CHAT1_SUB_OK);
    chat1_sub_list(100, out, 8, &count);
    assert(count == 2);
}

static void test_remove_not_found(void) {
    assert(chat1_sub_remove(100, 1) == CHAT1_SUB_ERR_NOT_FOUND);
    chat1_sub_add(100, 1);
    assert(chat1_sub_remove(100, 99) == CHAT1_SUB_ERR_NOT_FOUND);
}

static void test_remove_all(void) {
    uint64_t out[8];
    uint32_t count;
    chat1_sub_add(100, 1);
    chat1_sub_add(200, 1);
    chat1_sub_add(200, 2);
    chat1_sub_remove_all(1);
    chat1_sub_list(100, out, 8, &count);
    assert(count == 0);
    chat1_sub_list(200, out, 8, &count);
    assert(count == 1);
    assert(out[0] == 2);
}

static void test_empty_room_list(void) {
    uint64_t out[8];
    uint32_t count;
    assert(chat1_sub_list(999, out, 8, &count) == CHAT1_SUB_OK);
    assert(count == 0);
}

static void test_multiple_rooms(void) {
    uint64_t out[8];
    uint32_t count;
    chat1_sub_add(100, 1);
    chat1_sub_add(200, 2);
    chat1_sub_add(100, 3);
    chat1_sub_list(100, out, 8, &count);
    assert(count == 2);
    chat1_sub_list(200, out, 8, &count);
    assert(count == 1);
}

static void test_room_freed_when_empty(void) {
    uint64_t out[8];
    uint32_t count;
    chat1_sub_add(100, 1);
    chat1_sub_remove(100, 1);
    chat1_sub_list(100, out, 8, &count);
    assert(count == 0);
    assert(chat1_sub_add(100, 1) == CHAT1_SUB_OK);
}

static void test_list_truncation(void) {
    uint64_t out[2];
    uint32_t count;
    chat1_sub_add(100, 1);
    chat1_sub_add(100, 2);
    chat1_sub_add(100, 3);
    chat1_sub_list(100, out, 2, &count);
    assert(count == 2);
}

int main(void) {
    printf("test_sub_table:\n");
    RUN(test_add_and_list);
    RUN(test_duplicate);
    RUN(test_remove);
    RUN(test_remove_not_found);
    RUN(test_remove_all);
    RUN(test_empty_room_list);
    RUN(test_multiple_rooms);
    RUN(test_room_freed_when_empty);
    RUN(test_list_truncation);
    printf("ok %d/%d\n", tests_passed, tests_run);
    return 0;
}
