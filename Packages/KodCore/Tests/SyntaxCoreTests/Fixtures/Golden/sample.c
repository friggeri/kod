#include <stdio.h>

static int add(int lhs, int rhs) {
    return lhs + rhs;
}

int main(void) {
    printf("%d\n", add(2, 3));
    return 0;
}
