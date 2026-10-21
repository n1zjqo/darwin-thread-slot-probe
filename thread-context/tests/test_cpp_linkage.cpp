#include "thread_context.h"
#include "thread_context_backend.h"

#include <cstdio>

int main()
{
    tc_manager *manager = nullptr;
    tc_backend backend = tc_pthread_backend();
    int guest = 0;
    int readonly = 0;
    const tc_values values{ &guest, &readonly };
    tc_values actual{};
    if (tc_manager_create_with_backend(&manager, nullptr, &backend) != TC_OK ||
        tc_bind(manager, values) != TC_OK ||
        tc_get(manager, &actual) != TC_OK ||
        actual.guest_tls != &guest || actual.readonly_tls != &readonly ||
        tc_unbind(manager) != TC_OK ||
        tc_manager_destroy(&manager) != TC_OK || manager != nullptr) {
        return 1;
    }
    std::puts("c_and_cpp_backend_linkage PASS");
    return 0;
}
