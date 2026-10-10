#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

struct Monitor {
    int         x                = 0;
    int         y                = 0;
    int         width            = 1920;
    int         height           = 1080;
    int         workspace        = 1;
    std::string workspace_name   = "1";
    bool        focused          = false;
};

struct Placement {
    int  menu_left       = 8;
    int  menu_top        = 8;
    int  menu_w          = 380;
    int  menu_h          = 280;
    int         workspace      = 1;
    std::string workspace_name = "1";
    int  monitor_w       = 1920;
    int  monitor_h       = 1080;
    bool flyout_on_left  = false;
    int  flyout_left     = 0;
    int  flyout_w        = 260;
    int  flyout_gap      = 8;
};

int                      menu_width_for(int monitor_w);
const char*              hyprctl_bin();
bool                     parse_cursor_pos(const std::string& line, int& x, int& y);
std::vector<Monitor>     parse_monitors(const std::string& json);
Placement                place_menu(int cursor_x, int cursor_y, const std::vector<Monitor>& monitors, int menu_h);

struct Anchor {
    int left = 8;
    int top  = 8;
};

Anchor clamp_on_output(int global_x, int global_y, int width, int height, const std::vector<Monitor>& monitors);

struct Volume {
    double level = 0;
    bool   muted = true;
    bool   valid = false;
};

double      snap_volume(double value);
double      volume_fill(const Volume& volume);
bool        volume_overdrive(const Volume& volume);
std::string osd_label(const Volume& volume);
std::string menu_volume_caption(const Volume& volume);
std::string menu_volume_percent(const Volume& volume);
Volume      parse_wpctl(const std::string& text);
bool        operator==(const Volume& a, const Volume& b);

struct DesktopEntry {
    std::string              id;
    std::string              name;
    std::string              generic_name;
    std::string              comment;
    std::string              exec;
    std::string              icon;
    std::string              startup_class;
    std::string              path;
    std::vector<std::string> categories;
    std::vector<std::string> keywords;
    bool                     no_display  = false;
    bool                     hidden      = false;
    bool                     application = false;
};

std::optional<DesktopEntry> parse_desktop_text(const std::string& id, const std::string& path, const std::string& text);
std::string                 search_blob(const DesktopEntry& entry);
std::vector<DesktopEntry>   filter_apps(const std::vector<DesktopEntry>& apps, const std::string& category, const std::string& query);
std::vector<std::string>    entry_needles(const DesktopEntry& entry);
bool                        class_matches_needle(const std::string& klass, const std::string& needle);
std::string                 strip_exec_field_codes(const std::string& exec);
std::vector<std::string>    split_exec(const std::string& exec);
std::vector<DesktopEntry>   load_desktop_entries();
std::string                 resolve_icon_path(const std::string& name, const std::vector<std::string>& icon_bases, const std::vector<std::string>& pixmap_dirs);
std::string                 resolve_icon_path(const std::string& name);

struct Client {
    std::string address;
    std::string title;
    std::string klass;
    std::string initial_class;
    std::string workspace;
};

std::vector<Client> parse_clients(const std::string& json);
bool                is_minimized_workspace(const std::string& workspace);
bool                safe_window_address(const std::string& address);
std::vector<Client> windows_for_menu(const std::vector<Client>& all, bool minimized_only, bool& show_all);

struct SniTarget {
    std::string service;
    std::string path;
};

SniTarget resolve_sni_target(const std::string& argument, const std::string& sender);

enum class DeskCommand {
    Toggle,
    Open,
    Close,
    Unknown,
};

DeskCommand parse_command(const std::string& line);

struct StatsText {
    std::string cpu     = "cpu --";
    std::string mem     = "mem --";
    std::string gpu     = "gpu --";
    std::string net     = "net --";
    std::string cpu_max = "cpu 100%";
    std::string mem_max = "mem 8/8.0G";
    std::string gpu_max = "gpu 100%";
    std::string net_max = "eth unknown";
    std::string clock;
    std::string date;
};

struct CpuSample {
    uint64_t idle  = 0;
    uint64_t total = 0;
};

std::optional<CpuSample> read_cpu_sample();
int                      cpu_percent(const CpuSample& earlier, const CpuSample& later);
const char*              status_cpu_max();
std::string              status_cpu_text(int percent);
std::string              status_mem_text(unsigned used, unsigned whole, unsigned tenth);
std::string              status_mem_max(unsigned whole, unsigned tenth);
const char*              status_gpu_max();
std::string              status_gpu_text(const std::string& util, const std::string& temp);
std::string              status_net_text(const std::string& iface, const std::string& detail, bool wireless);
std::string              status_net_max(const std::string& iface, const std::string& detail);
StatsText                read_stats(const std::optional<CpuSample>& earlier);

bool run_self_test();

int         run_capture(const std::vector<std::string>& args, std::string& output);
void        run_detached(const std::vector<std::string>& args);
std::string desk_socket_path();
int         acquire_server_socket();
