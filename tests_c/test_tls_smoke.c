#include <assert.h>
#include <stdio.h>

int chat1_tls_init(void);

int main(void) {
    assert(chat1_tls_init() == 0);
    printf("ok tls init\n");
    return 0;
}
