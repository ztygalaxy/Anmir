#include <assert.h>
#include <math.h>
#include <stdint.h>
#include "sys/macos/ios_hid.h"

int main(void) {
    uint8_t down[58], up[58];
    assert(sc_ios_hid_touch(down, 0, 1, 0));
    assert(down[0] == 9 && down[1] == 1 && down[2] == 1);
    assert(down[3] == 0xc0 && down[4] == 0 && down[5] == 0);
    assert(down[6] == 255 && down[7] == 255);
    for (size_t i = 8; i < sizeof(down); i++) { assert(down[i] == 0); }
    assert(sc_ios_hid_touch(up, 0, 1, 2));
    assert(up[1] == 1 && up[3] == 0);
    down[3] = 0;
    assert(memcmp(down, up, sizeof(down)) == 0);
    assert(sc_ios_hid_touch(down, -.5, 2, 1));
    assert(down[4] == 0 && down[5] == 0 && down[6] == 255 && down[7] == 255);
    assert(sc_ios_hid_touch(down, .5, .5, 1));
    assert(down[4] == 0 && down[5] == 128 && down[6] == 0 && down[7] == 128);
    assert(!sc_ios_hid_touch(down, NAN, .5, 0));
    assert(!sc_ios_hid_touch(down, .5, INFINITY, 0));
    assert(!sc_ios_hid_touch(down, .5, .5, 3));
    return 0;
}
