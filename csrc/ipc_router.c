#include "chat1_ffi.h"

int chat1_route_batch_to_owner(const chat1_ingress_batch *batch) {
    if (!batch) {
        return CHAT1_ROUTE_ERR_INVALID;
    }

    return CHAT1_ROUTE_ERR_UNIMPLEMENTED;
}
