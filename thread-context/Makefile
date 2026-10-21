CC ?= cc
CXX ?= c++
AR ?= ar
CPPFLAGS += -Iinclude -Isrc
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -Werror -pedantic
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Werror -pedantic
LDFLAGS ?=
BUILD ?= build

.PHONY: all test diagnostic-build test-diagnostic clean
all: $(BUILD)/libthread_context.a $(BUILD)/test_thread_context $(BUILD)/test_slot_candidate $(BUILD)/test_cpp_linkage

$(BUILD):
	mkdir -p $@

$(BUILD)/thread_context.o: src/thread_context.c include/thread_context.h include/thread_context_backend.h src/slot_candidate.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -pthread -c src/thread_context.c -o $@

$(BUILD)/libthread_context.a: $(BUILD)/thread_context.o
	$(AR) rcs $@ $<

$(BUILD)/test_cpp_linkage: tests/test_cpp_linkage.cpp $(BUILD)/libthread_context.a include/thread_context_backend.h
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -pthread $< $(BUILD)/libthread_context.a $(LDFLAGS) -o $@

$(BUILD)/test_thread_context: src/thread_context.c include/thread_context.h include/thread_context_backend.h src/slot_candidate.h tests/test_thread_context.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -pthread src/thread_context.c tests/test_thread_context.c $(LDFLAGS) -o $@

$(BUILD)/test_slot_candidate: tests/test_slot_candidate.c src/slot_candidate.h include/thread_context.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) tests/test_slot_candidate.c $(LDFLAGS) -o $@

$(BUILD)/test_thread_context_diagnostic: src/thread_context.c include/thread_context.h include/thread_context_backend.h src/slot_candidate.h tests/test_thread_context.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -DTC_ENABLE_DARWIN_DIAGNOSTIC=1 -pthread src/thread_context.c tests/test_thread_context.c $(LDFLAGS) -o $@

test: all
	./$(BUILD)/test_thread_context
	./$(BUILD)/test_slot_candidate
	./$(BUILD)/test_cpp_linkage

diagnostic-build: $(BUILD)/test_thread_context_diagnostic

test-diagnostic: diagnostic-build
	./$(BUILD)/test_thread_context_diagnostic

clean:
	rm -rf $(BUILD)
