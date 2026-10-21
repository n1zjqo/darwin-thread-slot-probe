#include "thread_context_backend.h"
int main() {
    tc_manager *m = nullptr;
    tc_backend b = tc_pthread_backend();
    if (tc_manager_create_with_backend(&m, nullptr, &b) != TC_OK) return 1;
    return tc_manager_destroy(&m) == TC_OK ? 0 : 2;
}
