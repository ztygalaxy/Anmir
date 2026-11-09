#ifndef SC_IOS_HID_H
#define SC_IOS_HID_H
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

// UniversalHID's 464-bit digitizer descriptor. Lift still describes one
// contact, with Touch/InRange cleared; omitting it leaves a finger held down.
// Ordinary touch layout adapted from ipb's MIT universalhid_glue.swift. The
// special bottom-edge shape uses different identity/time/swipe fields and must
// not be mixed into ordinary taps, drags or left-edge navigation.
static inline bool
sc_ios_hid_touch(uint8_t report[58], double x, double y, unsigned phase) {
    if (phase > 2 || !isfinite(x) || !isfinite(y)) { return false; }
    memset(report, 0, 58);
    report[0] = 9; report[1] = 1; report[2] = 1;
    report[3] = phase == 2 ? 0 : 0xc0;
    uint16_t px = (uint16_t)lrint(fmin(1, fmax(0, x)) * 65535);
    uint16_t py = (uint16_t)lrint(fmin(1, fmax(0, y)) * 65535);
    report[4] = px; report[5] = px >> 8; report[6] = py; report[7] = py >> 8;
    return true;
}
#endif
