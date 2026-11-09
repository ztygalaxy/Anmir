#include "common.h"

#include <assert.h>
#include <math.h>
#include <string.h>
#include "icon.h"
#include "toolbar.h"

SDL_Surface *
sc_icon_load(const char *filename) {
    (void) filename;
    return NULL;
}

void
sc_icon_destroy(SDL_Surface *icon) {
    (void) icon;
}

static void
test_toolbar_layout_and_hit_test(void) {
    struct sc_toolbar toolbar;
    sc_toolbar_init(&toolbar, true, false);
    sc_toolbar_layout(&toolbar);

    assert(!toolbar.user_visible);
    assert(toolbar.panel.w == SC_TOOLBAR_PANEL_WIDTH);
    assert(toolbar.panel.h == SC_TOOLBAR_PANEL_HEIGHT);
    assert(SC_TOOLBAR_PANEL_WIDTH == 48);
    assert(SC_TOOLBAR_BUTTON_HEIGHT == 48);
    assert((SC_TOOLBAR_PANEL_WIDTH - SC_TOOLBAR_ICON_SIZE) / 2 == 16);
    assert((SC_TOOLBAR_BUTTON_HEIGHT - SC_TOOLBAR_ICON_SIZE) / 2 == 16);
    assert(toolbar.buttons[SC_TOOLBAR_ACTION_HOME].y
           < toolbar.buttons[SC_TOOLBAR_ACTION_BACK].y);
    assert(toolbar.buttons[SC_TOOLBAR_ACTION_BACK].y
           < toolbar.buttons[SC_TOOLBAR_ACTION_RECENTS].y);
    assert(toolbar.buttons[SC_TOOLBAR_ACTION_RECENTS].y
           < toolbar.buttons[SC_TOOLBAR_ACTION_SCREENSHOT].y);
    assert(toolbar.buttons[SC_TOOLBAR_ACTION_SCREENSHOT].y
           < toolbar.buttons[SC_TOOLBAR_ACTION_RECORD].y);
    assert(toolbar.buttons[SC_TOOLBAR_ACTION_SCREENSHOT].y
           - (toolbar.buttons[SC_TOOLBAR_ACTION_RECENTS].y
              + SC_TOOLBAR_BUTTON_HEIGHT) == SC_TOOLBAR_SEPARATOR_HEIGHT);
    assert(!sc_toolbar_is_left_of_parent(&toolbar));
    assert(sc_toolbar_action_center_y(&toolbar, SC_TOOLBAR_ACTION_RECORD)
           == toolbar.buttons[SC_TOOLBAR_ACTION_RECORD].y
            + SC_TOOLBAR_BUTTON_HEIGHT / 2.f);

    for (enum sc_toolbar_action action = SC_TOOLBAR_ACTION_HOME;
            action < SC_TOOLBAR_ACTION_COUNT; ++action) {
        SDL_FRect rect = toolbar.buttons[action];
        enum sc_toolbar_action hit =
            sc_toolbar_hit_test(&toolbar, rect.x + rect.w / 2.f,
                                rect.y + rect.h / 2.f);
        assert(hit == action);
    }

    assert(sc_toolbar_hit_test(&toolbar, 0.f, 0.f)
           == SC_TOOLBAR_ACTION_NONE);
    assert(!sc_toolbar_contains(&toolbar, toolbar.panel.x,
                                toolbar.panel.y));
    assert(!sc_toolbar_contains(&toolbar, toolbar.panel.x + 1.f,
                                toolbar.panel.y + toolbar.panel.h - 1.f));
}

static void
test_toolbar_screenshot_feedback(void) {
    struct sc_toolbar toolbar;
    sc_toolbar_init(&toolbar, true, true);
    assert(!sc_toolbar_screenshot_success_active(&toolbar));
    sc_toolbar_show_screenshot_success(&toolbar);
    assert(sc_toolbar_screenshot_success_active(&toolbar));
    toolbar.screenshot_success_until = SDL_GetTicks();
    assert(!sc_toolbar_screenshot_success_active(&toolbar));
}

static void
test_toolbar_initial_visibility(void) {
    struct sc_toolbar toolbar;

    sc_toolbar_init(&toolbar, true, false);
    assert(!toolbar.user_visible);

    sc_toolbar_init(&toolbar, true, true);
    assert(toolbar.user_visible);

    sc_toolbar_init(&toolbar, false, true);
    assert(!toolbar.user_visible);
}

static void
test_disabled_toolbar(void) {
    struct sc_toolbar toolbar;
    sc_toolbar_init(&toolbar, false, false);
    sc_toolbar_layout(&toolbar);

    assert(!sc_toolbar_contains(&toolbar, 10.f, 10.f));
    assert(sc_toolbar_hit_test(&toolbar, toolbar.panel.x + 30.f,
                               toolbar.panel.y + 36.f)
           == SC_TOOLBAR_ACTION_NONE);
}

static void
test_native_toolbar_snapshot(void) {
    struct sc_toolbar toolbar;
    sc_toolbar_init(&toolbar, true, true);
    struct sc_toolbar_view_state state = {
        .navigation_enabled = true,
        .screenshot_enabled = true,
        .record_enabled = true,
    };
    assert(!sc_toolbar_render_snapshot(&toolbar, &state, 0));
    assert(!sc_toolbar_render_snapshot(&toolbar, &state, NAN));
    assert(!sc_toolbar_render_snapshot(&toolbar, &state, 10));
    SDL_Surface *normal = sc_toolbar_render_snapshot(&toolbar, &state, 2);
    assert(normal);
    assert(normal->w == SC_TOOLBAR_WINDOW_WIDTH * 2);
    assert(normal->h == SC_TOOLBAR_WINDOW_HEIGHT * 2);
    assert(normal->format == SDL_PIXELFORMAT_RGBA32);
    // The native host must not paint its own solid rectangle over the shadow.
    const uint8_t *pixels = normal->pixels;
    assert(pixels[3] == 0);
    // RLE-backed software textures used to turn the translucent shadow into
    // fully opaque black. Check both exposed sides, not just a clear corner.
    int shadow_x = (SC_TOOLBAR_SHADOW_MARGIN + SC_TOOLBAR_PANEL_WIDTH + 1) * 2;
    int shadow_y = (SC_TOOLBAR_SHADOW_MARGIN + SC_TOOLBAR_PANEL_HEIGHT + 2) * 2;
    const uint8_t *right_shadow = pixels + 100 * 2 * normal->pitch + shadow_x * 4;
    const uint8_t *bottom_shadow = pixels + shadow_y * normal->pitch
        + (SC_TOOLBAR_SHADOW_MARGIN + SC_TOOLBAR_PANEL_WIDTH / 2) * 2 * 4;
    assert(right_shadow[3] > 0 && right_shadow[3] <= 62);
    assert(bottom_shadow[3] > 0 && bottom_shadow[3] <= 62);
    state.disabled_actions = UINT32_C(1) << SC_TOOLBAR_ACTION_BACK;
    SDL_Surface *disabled = sc_toolbar_render_snapshot(&toolbar, &state, 2);
    assert(disabled);
    bool back_changed = false;
    for (int y = 0; y < normal->h; ++y) {
        const uint8_t *a = (const uint8_t *)normal->pixels + y * normal->pitch;
        const uint8_t *b = (const uint8_t *)disabled->pixels + y * disabled->pitch;
        bool same = !memcmp(a, b, normal->w * 4);
        SDL_FRect back = toolbar.buttons[SC_TOOLBAR_ACTION_BACK];
        if (y >= back.y * 2 && y < (back.y + back.h) * 2) { back_changed |= !same; }
        else { assert(same); }
    }
    assert(back_changed);
    // Snapshot rendering leaves an Android toolbar's live state untouched.
    assert(!toolbar.renderer && !toolbar.window && !toolbar.render_cache);
    assert(toolbar.hovered == SC_TOOLBAR_ACTION_NONE);
    SDL_DestroySurface(normal);
    SDL_DestroySurface(disabled);
}

int
main(int argc, char *argv[]) {
    (void) argc;
    (void) argv;

    test_toolbar_layout_and_hit_test();
    test_toolbar_screenshot_feedback();
    test_toolbar_initial_visibility();
    test_disabled_toolbar();
    test_native_toolbar_snapshot();
    return 0;
}
