#include "logic.hpp"
#include "tray.hpp"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <unistd.h>

namespace {

int g_failures = 0;

void expect(bool condition, const char* text, int line) {
    if (condition)
        return;
    std::fprintf(stderr, "self-test failed:%d %s\n", line, text);
    ++g_failures;
}

} // namespace

#define EXPECT(cond) expect((cond), #cond, __LINE__)

bool run_self_test() {
    EXPECT(std::abs(snap_volume(0.026) - 0.025) < 0.0001);
    EXPECT(std::abs(snap_volume(1.6) - 1.5) < 0.0001);
    EXPECT(snap_volume(-1) == 0);
    EXPECT(std::abs(snap_volume(0.125) - 0.125) < 0.0001);

    Volume muted{.level = 1.2, .muted = true, .valid = true};
    Volume hot{.level = 1.025, .muted = false, .valid = true};
    Volume half{.level = 0.5, .muted = false, .valid = true};
    Volume eighth{.level = 0.125, .muted = false, .valid = true};
    EXPECT(volume_fill(muted) == 0);
    EXPECT(!volume_overdrive(muted));
    EXPECT(volume_overdrive(hot));
    EXPECT(!volume_overdrive(Volume{.level = 1.0, .muted = false, .valid = true}));
    EXPECT(!volume_overdrive(Volume{}));
    EXPECT(std::abs(volume_fill(half) - (0.5 / 1.5)) < 0.0001);
    EXPECT(osd_label(Volume{}) == "--%");
    EXPECT(menu_volume_caption(Volume{}) == "--");
    EXPECT(volume_fill(Volume{}) == 0);
    EXPECT(menu_volume_caption(Volume{.level = 0, .muted = false, .valid = true}) == "MUTE");
    EXPECT(osd_label(muted) == "MUTE");
    EXPECT(osd_label(half) == "50%");
    EXPECT(osd_label(eighth) == "12.5%");
    EXPECT(osd_label(Volume{.level = 1.5, .muted = false, .valid = true}) == "150%");
    EXPECT(osd_label(parse_wpctl("Volume: 0.73\n")) == "72.5%");
    EXPECT(osd_label(parse_wpctl("Volume: 1.13\n")) == "112.5%");
    EXPECT(osd_label(parse_wpctl("Volume: 1.50\n")) == "150%");
    EXPECT(osd_label(parse_wpctl("Volume: 0.50\n")) == "50%");
    EXPECT(menu_volume_caption(half) == "VOL");
    EXPECT(menu_volume_caption(muted) == "MUTE");
    EXPECT(menu_volume_percent(muted) == "0%");
    EXPECT(menu_volume_percent(Volume{}) == "--%");
    EXPECT(menu_volume_percent(parse_wpctl("Volume: 0.73\n")) == "72.5%");
    EXPECT(parse_wpctl("Volume: 0.50 [MUTED]\n").muted);
    EXPECT(std::abs(parse_wpctl("Volume: 1.10\n").level - 1.10) < 0.001);
    EXPECT(!parse_wpctl("nope").valid);

    int x = 0;
    int y = 0;
    EXPECT(parse_cursor_pos("100, 200", x, y) && x == 100 && y == 200);
    const char* monitors_json =
        R"([{"id":0,"name":"A","x":0,"y":0,"width":1920,"height":1080,"focused":true,"activeWorkspace":{"id":3,"name":"3"}},{"id":1,"name":"B","x":1920,"y":0,"width":1280,"height":1024,"focused":false,"activeWorkspace":{"id":2,"name":"2"}}])";
    auto monitors = parse_monitors(monitors_json);
    EXPECT(monitors.size() == 2);
    EXPECT(monitors[0].name == "A");
    EXPECT(monitors[1].name == "B");
    EXPECT(monitors[0].focused && monitors[0].workspace == 3);
    EXPECT(monitors[0].workspace_name == "3");
    EXPECT(monitors[1].x == 1920 && !monitors[1].focused);
    auto placed = place_menu(100, 200, monitors, 500);
    EXPECT(placed.menu_left == 100 && placed.menu_top == 200);
    EXPECT(placed.workspace == 3);
    EXPECT(placed.workspace_name == "3");
    EXPECT(placed.menu_w == 422);
    EXPECT(placed.monitor_name == "A");
    EXPECT(!placed.flyout_on_left);
    auto edge = place_menu(1900, 1000, monitors, 400);
    auto wide = edge;
    fit_menu_width(wide, edge.menu_w + 40);
    EXPECT(wide.menu_w == edge.menu_w + 40);
    EXPECT(wide.menu_left == 1920 - wide.menu_w - 8);
    EXPECT(wide.menu_left + wide.menu_w <= 1920 - 8);
    EXPECT(edge.menu_left == 1920 - edge.menu_w - 8);
    auto held = edge;
    fit_menu_width(held, edge.menu_w - 10);
    EXPECT(held.menu_w == edge.menu_w);
    Placement narrow;
    narrow.menu_w    = 0;
    narrow.monitor_w = 1920;
    fit_menu_width(narrow, 0);
    EXPECT(narrow.menu_w == 1);
    const auto fitted = menu_bands(menu_height_for(kMenuWindowCap), kMenuWindowCap);
    EXPECT(fitted.top == kMenuCategoryBlock);
    EXPECT(fitted.windows == (kMenuWindowCap * kMenuWindowRow) + ((kMenuWindowCap - 1) * kMenuWindowGap));
    const auto extra_windows = menu_bands(menu_height_for(kMenuWindowCap), 40);
    EXPECT(extra_windows.top == fitted.top && extra_windows.windows == fitted.windows);
    const auto few = menu_bands(menu_height_for(kMenuWindowCap), 2);
    EXPECT(few.top == fitted.top && few.windows < fitted.windows);
    const auto squeezed = menu_bands(menu_height_for(kMenuWindowCap) - 50, kMenuWindowCap);
    EXPECT(squeezed.top == fitted.top && squeezed.windows == fitted.windows - 50);
    const auto cramped = menu_bands(400, kMenuWindowCap);
    EXPECT(cramped.top < fitted.top && cramped.windows > 0);
    EXPECT(cramped.top + cramped.windows == 400 - kMenuChrome);
    const auto empty_list = menu_bands(menu_height_for(0), 0);
    EXPECT(empty_list.top == kMenuCategoryBlock && empty_list.windows == kMenuWindowEmpty);
    EXPECT(edge.menu_top == 1080 - edge.menu_h - 8);
    EXPECT(edge.flyout_on_left);
    auto other = place_menu(2000, 10, monitors, 400);
    EXPECT(other.monitor_w == 1280);
    EXPECT(other.monitor_name == "B");
    EXPECT(other.workspace == 2 && other.workspace_name == "2");
    const char* named_json =
        R"([{"id":0,"name":"A","x":0,"y":0,"width":1920,"height":1080,"focused":true,"activeWorkspace":{"id":-1337,"name":"code-1"}}])";
    auto named = parse_monitors(named_json);
    EXPECT(named.size() == 1 && named[0].workspace == -1337 && named[0].workspace_name == "code-1");
    auto named_place = place_menu(20, 20, named, 400);
    EXPECT(named_place.workspace == -1337 && named_place.workspace_name == "code-1");
    auto popup = clamp_on_output(100, 120, 240, 80, monitors);
    EXPECT(popup.left == 100 && popup.top == 120);
    auto popup_edge = clamp_on_output(1900, 1000, 240, 200, monitors);
    EXPECT(popup_edge.left == 1920 - 240 - 8);
    EXPECT(popup_edge.top == 1080 - 200 - 8);

    const char* desktop = R"([Desktop Entry]
Type=Application
Name=Terminal
GenericName=Console
Comment=A shell
Exec=kitty %f
Icon=kitty
Categories=System;Utility;
Keywords=term;
StartupWMClass=kitty
)";
    auto entry = parse_desktop_text("kitty.desktop", "/tmp/kitty.desktop", desktop);
    EXPECT(entry.has_value());
    EXPECT(entry->name == "Terminal");
    EXPECT(filter_apps({*entry}, "Game", "").empty());
    EXPECT(filter_apps({*entry}, "Utility", "term").size() == 1);
    EXPECT(filter_apps({*entry}, "*", "missing").empty());
    auto hidden = *entry;
    hidden.no_display = true;
    EXPECT(filter_apps({hidden}, "*", "").empty());
    char icon_dir[] = "/tmp/hyprdesk-icon-XXXXXX";
    EXPECT(mkdtemp(icon_dir) != nullptr);
    const std::string icon_root = icon_dir;
    const std::string hicolor   = icon_root + "/hicolor";
    std::filesystem::create_directories(hicolor + "/scalable/apps");
    std::filesystem::create_directories(hicolor + "/22x22/apps");
    std::filesystem::create_directories(hicolor + "/64x64/apps");
    std::filesystem::create_directories(hicolor + "/256x256/apps");
    std::filesystem::create_directories(icon_root + "/pix");
    {
        std::ofstream svg(hicolor + "/scalable/apps/multimc.svg");
        svg << "<svg xmlns=\"http://www.w3.org/2000/svg\"/>";
        std::ofstream png(hicolor + "/scalable/apps/multimc.png");
        png << "png";
        std::ofstream guild(hicolor + "/256x256/apps/guild-wars.png");
        guild << "png";
        std::ofstream boinc_svg(hicolor + "/scalable/apps/boinc.svg");
        boinc_svg << "<svg xmlns=\"http://www.w3.org/2000/svg\"/>";
        std::ofstream boinc_png(hicolor + "/64x64/apps/boinc.png");
        boinc_png << "png";
        std::ofstream only_svg(hicolor + "/scalable/apps/only.svg");
        only_svg << "<svg xmlns=\"http://www.w3.org/2000/svg\"/>";
        std::ofstream near(hicolor + "/22x22/apps/near.png");
        near << "png";
        std::ofstream far(hicolor + "/256x256/apps/near.png");
        far << "png";
        std::ofstream pixmap(icon_root + "/pix/only-pixmap.png");
        pixmap << "png";
        std::ofstream absolute(icon_root + "/absolute.png");
        absolute << "png";
    }
    std::filesystem::create_directories(icon_root + "/later/22x22/apps");
    {
        std::ofstream big_svg(hicolor + "/scalable/apps/big.svg");
        big_svg << "<svg xmlns=\"http://www.w3.org/2000/svg\"/>";
        std::ofstream big_png(hicolor + "/256x256/apps/big.png");
        big_png << "png";
        std::ofstream later(icon_root + "/later/22x22/apps/near.png");
        later << "png";
    }
    const std::vector<std::string> bases{hicolor};
    const std::vector<std::string> pix{icon_root + "/pix"};
    EXPECT(resolve_icon_path("multimc", bases, pix) == hicolor + "/scalable/apps/multimc.png");
    EXPECT(resolve_icon_path("boinc", bases, pix) == hicolor + "/64x64/apps/boinc.png");
    EXPECT(resolve_icon_path("only", bases, pix) == hicolor + "/scalable/apps/only.svg");
    EXPECT(resolve_icon_path("guild-wars", bases, pix) == hicolor + "/256x256/apps/guild-wars.png");
    EXPECT(resolve_icon_path("near", bases, pix) == hicolor + "/22x22/apps/near.png");
    EXPECT(resolve_icon_path("big", bases, pix) == hicolor + "/scalable/apps/big.svg");
    EXPECT(resolve_icon_path("near", std::vector<std::string>{hicolor, icon_root + "/later"}, pix) == hicolor + "/22x22/apps/near.png");
    EXPECT(resolve_icon_path("near", std::vector<std::string>{icon_root + "/later", hicolor}, pix) == icon_root + "/later/22x22/apps/near.png");
    EXPECT(icon_theme_from_kdeglobals("[Icons]\nTheme=Tango\n\n[KDE]\nTheme=breeze_cursors\n") == "Tango");
    EXPECT(icon_theme_from_kdeglobals("[KDE]\nTheme=breeze_cursors\n").empty());
    EXPECT(resolve_icon_path("only-pixmap", bases, pix) == icon_root + "/pix/only-pixmap.png");
    EXPECT(resolve_icon_path("missing", bases, pix).empty());
    EXPECT(resolve_icon_path(icon_root + "/absolute.png", bases, pix) == icon_root + "/absolute.png");
    EXPECT(resolve_icon_path(icon_root + "/nope.png", bases, pix).empty());
    std::filesystem::remove_all(icon_root);
    EXPECT(strip_exec_field_codes("kitty %f --class %c %%") == "kitty  --class  %");
    auto args = split_exec("\"code\" -- %f");
    EXPECT(args.size() == 2 && args[0] == "code" && args[1] == "--");
    auto code = *entry;
    code.id = "code.desktop";
    code.name = "Visual Studio Code";
    code.startup_class = "com.microsoft.VSCode";
    auto needles = entry_needles(code);
    EXPECT(std::find(needles.begin(), needles.end(), "code") != needles.end());
    EXPECT(class_matches_needle("code", "code"));
    EXPECT(class_matches_needle("org.wezfurlong.wezterm", "wezterm"));
    EXPECT(!class_matches_needle("abcd", "ab"));

    const char* clients_json =
        R"([{"address":"0xabc","title":"Notes","class":"code","initialClass":"code","workspace":{"id":1,"name":"special:minimized"}},{"address":"0x10","title":"Browser","class":"brave","initialClass":"brave","workspace":{"id":2,"name":"2"}},{"address":"bad","title":"Skip","class":"x","workspace":{"name":"1"}}])";
    auto clients = parse_clients(clients_json);
    EXPECT(clients.size() == 3);
    EXPECT(clients[0].workspace == "special:minimized");
    EXPECT(is_minimized_workspace("special:minimized"));
    EXPECT(!is_minimized_workspace("2"));
    bool show_all = false;
    auto minimized = windows_for_menu(clients, true, show_all);
    EXPECT(!show_all && minimized.size() == 1 && minimized[0].address == "0xabc");
    Client only = clients[1];
    show_all = false;
    auto flipped = windows_for_menu({only}, true, show_all);
    EXPECT(show_all && flipped.size() == 1);
    EXPECT(safe_window_address("0xabc"));
    EXPECT(!safe_window_address("bad"));
    EXPECT(!safe_window_address("0xzzzz"));

    EXPECT(resolve_sni_target("/StatusNotifierItem", "org.example.Tray").path == "/StatusNotifierItem");
    EXPECT(resolve_sni_target("/StatusNotifierItem", "org.example.Tray").service == "org.example.Tray");
    EXPECT(resolve_sni_target("org.kde.StatusNotifierItem-1-2", "org.example.Tray").path == "/StatusNotifierItem");
    EXPECT(parse_command("toggle\n") == DeskCommand::Toggle);
    EXPECT(parse_command("open") == DeskCommand::Open);
    EXPECT(parse_command("close\r") == DeskCommand::Close);
    EXPECT(parse_command("nope") == DeskCommand::Unknown);

    CpuSample earlier{10, 100};
    CpuSample later{20, 200};
    EXPECT(cpu_percent(earlier, later) == 90);
    EXPECT(std::string(status_cpu_max()) == "cpu 100%");
    EXPECT(status_cpu_text(9) == "cpu 9%");
    EXPECT(status_cpu_text(100) == "cpu 100%");
    EXPECT(status_mem_text(5, 62, 9) == "mem 5/62.9G");
    EXPECT(status_mem_max(62, 9) == "mem 88/62.9G");
    EXPECT(status_mem_max(128, 0) == "mem 888/128.0G");
    EXPECT(std::string(status_gpu_max()) == "gpu 100% 100°");
    EXPECT(status_gpu_text("40", "61") == "gpu 40% 61°");
    EXPECT(status_gpu_text("40", "") == "gpu 40%");
    EXPECT(status_net_text("enp6s0", "up", false) == "eth enp6s0 up");
    EXPECT(status_net_max("enp6s0", "up") == "eth enp6s0 unknown");
    EXPECT(status_net_text("wlan0", "Home", true) == "eth Home");
    EXPECT(status_net_max("wlan0", "Home") == "eth wlan0 unknown");
    EXPECT(status_net_max("", "") == "eth --");
    const uint8_t pixel[] = {255, 255, 0, 0};
    const auto    png     = argb_to_png(1, 1, pixel, 4);
    EXPECT(png.size() >= 8 && png[0] == 0x89 && png[1] == 'P' && png[2] == 'N' && png[3] == 'G');
    EXPECT(argb_to_png(1, 1, pixel, 4) == png);
    EXPECT(argb_to_png(0, 1, pixel, 4).empty());
    EXPECT(argb_to_png(1, 1, pixel, 2).empty());
    EXPECT(tray_popup_height({}) == 12 + 28);
    TrayMenuItem tray_row;
    TrayMenuItem tray_gap;
    tray_gap.separator = true;
    EXPECT(tray_popup_height({tray_row, tray_gap, tray_row}) == 12 + 28 + 2 + 1 + 2 + 28);

    EXPECT(capture_wait_code(-1, 0, ECHILD) == 0);
    EXPECT(capture_wait_code(-1, 0, EINTR) == 1);
    EXPECT(capture_wait_code(1, 0, 0) == 0);
    EXPECT(capture_wait_code(1, 256, 0) == 1);
    EXPECT(capture_wait_code(1, 9, 0) == 1);
    std::string captured;
    EXPECT(run_capture({"/bin/echo", "ok"}, captured) == 0);
    EXPECT(captured.find("ok") != std::string::npos);
    EXPECT(run_capture({"/bin/false"}, captured) != 0);

    run_detached({"/bin/true"});
    bool reaped = false;
    for (int i = 0; i < 50 && !reaped; ++i) {
        if (reap_detached() > 0)
            reaped = true;
        else
            usleep(10000);
    }
    EXPECT(reaped);

    if (g_failures != 0)
        return false;
    std::puts("hyprdesk self-test passed");
    return true;
}
