#include "ui.hpp"

#include "logic.hpp"
#include "tray.hpp"

#include <hyprtoolkit/core/Backend.hpp>
#include <hyprtoolkit/core/Output.hpp>
#include <hyprtoolkit/core/Timer.hpp>
#include <hyprtoolkit/system/Icons.hpp>
#include <hyprtoolkit/element/Button.hpp>
#include <hyprtoolkit/element/ColumnLayout.hpp>
#include <hyprtoolkit/element/Image.hpp>
#include <hyprtoolkit/element/Rectangle.hpp>
#include <hyprtoolkit/element/RowLayout.hpp>
#include <hyprtoolkit/element/ScrollArea.hpp>
#include <hyprtoolkit/element/Slider.hpp>
#include <hyprtoolkit/element/Text.hpp>
#include <hyprtoolkit/element/Textbox.hpp>
#include <hyprtoolkit/window/Window.hpp>

#include <xkbcommon/xkbcommon-keysyms.h>

#include <pango/pangocairo.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fcntl.h>
#include <mutex>
#include <sstream>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>

using namespace Hyprtoolkit;
using Hyprutils::Math::Vector2D;
using Hyprutils::Memory::CAtomicSharedPointer;
using Hyprutils::Memory::CSharedPointer;

namespace {

constexpr uint32_t kAnchorTopLeft = 1 | 4;
constexpr uint32_t kAnchorAll     = 1 | 2 | 4 | 8;
constexpr int      kEscape        = XKB_KEY_Escape;

CDynamicSize percent_box(float x, float y) {
    return {CDynamicSize::HT_SIZE_PERCENT, CDynamicSize::HT_SIZE_PERCENT, {x, y}};
}

CDynamicSize bar_size(float width, float height) {
    return {CDynamicSize::HT_SIZE_PERCENT, CDynamicSize::HT_SIZE_ABSOLUTE, {width, height}};
}

CDynamicSize box_size(float width, float height) {
    return {CDynamicSize::HT_SIZE_ABSOLUTE, CDynamicSize::HT_SIZE_ABSOLUTE, {width, height}};
}

struct LabelExtent {
    float width  = 1.F;
    float height = 18.F;
};

LabelExtent measure_label(const std::string& text, const std::string& family, float pt) {
    PangoFontMap*         map     = pango_cairo_font_map_get_default();
    PangoContext*         context = pango_font_map_create_context(map);
    PangoLayout*          layout  = pango_layout_new(context);
    PangoFontDescription* desc    = pango_font_description_from_string(family.empty() ? "Sans Serif" : family.c_str());
    pango_font_description_set_size(desc, static_cast<int>(std::lround(pt)) * PANGO_SCALE);
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);
    pango_layout_set_text(layout, text.c_str(), static_cast<int>(text.size()));
    PangoRectangle logical{};
    pango_layout_get_pixel_extents(layout, nullptr, &logical);
    g_object_unref(layout);
    g_object_unref(context);
    LabelExtent extent;
    extent.width  = static_cast<float>(std::max(logical.width, 1));
    extent.height = static_cast<float>(std::max(logical.height, 1));
    return extent;
}

float status_fields_width(const StatsText& stats, const std::string& family, float pt) {
    constexpr float gap   = 10.F;
    float           width = 0.F;
    for (const std::string* field : {&stats.cpu_max, &stats.mem_max, &stats.gpu_max, &stats.net_max})
        width += measure_label(*field, family, pt).width + gap;
    return width > gap ? width - gap : width;
}

CSharedPointer<CImageElement> image_for_name(IBackend* backend, const std::string& name, const std::string& theme_path, float side, bool sync_load) {
    auto sized = [&](CSharedPointer<CImageBuilder> builder) {
        return builder->fitMode(IMAGE_FIT_MODE_CONTAIN)->sync(sync_load)->size(box_size(side, side))->commence();
    };
    if (name.empty())
        return {};
    if (name.front() == '/') {
        if (access(name.c_str(), R_OK) == 0)
            return sized(CImageBuilder::begin()->path(std::string{name}));
        return {};
    }
    // The file walk uses the KDE icon theme and the closest size. The
    // toolkit lookup is only the fallback when that walk misses.
    if (const auto path = resolve_icon_path(name); !path.empty())
        return CImageBuilder::begin()->path(std::string{path})->fitMode(IMAGE_FIT_MODE_CONTAIN)->sync(true)->size(box_size(side, side))->commence();
    if (auto picture = backend->systemIcons()->lookupIcon(name); picture && picture->exists())
        return sized(CImageBuilder::begin()->icon(picture));
    if (!theme_path.empty()) {
        for (const char* ext : {"", ".png", ".svg", ".xpm"}) {
            std::string path = theme_path;
            if (!path.empty() && path.back() != '/')
                path.push_back('/');
            path += name;
            path += ext;
            if (access(path.c_str(), R_OK) == 0)
                return sized(CImageBuilder::begin()->path(std::move(path)));
        }
    }
    return {};
}

bool read_pointer(int& x, int& y) {
    std::string cursor;
    if (run_capture({hyprctl_bin(), "cursorpos"}, cursor) != 0)
        return false;
    return parse_cursor_pos(cursor, x, y);
}

bool box_contains(int x, int y, int left, int top, int width, int height, int pad) {
    return x >= left - pad && x < left + width + pad && y >= top - pad && y < top + height + pad;
}

struct PopupPlace {
    int global_x = 0;
    int global_y = 0;
    int local_x  = 8;
    int local_y  = 8;
};

const Monitor* monitor_at(int x, int y, const std::vector<Monitor>& monitors) {
    for (const auto& monitor : monitors) {
        if (x >= monitor.x && x < monitor.x + monitor.width && y >= monitor.y && y < monitor.y + monitor.height)
            return &monitor;
    }
    for (const auto& monitor : monitors) {
        if (monitor.focused)
            return &monitor;
    }
    return monitors.empty() ? nullptr : &monitors.front();
}

const Monitor* named_monitor(const std::vector<Monitor>& monitors, const std::string& name) {
    if (name.empty())
        return nullptr;
    for (const auto& monitor : monitors) {
        if (monitor.name == name)
            return &monitor;
    }
    return nullptr;
}

void bind_output(const CSharedPointer<CWindowBuilder>& builder, IBackend* backend, const std::string& port) {
    if (!builder || !backend || port.empty())
        return;
    for (const auto& output : backend->getOutputs()) {
        if (output && output->port() == port) {
            builder->prefferedOutput(output);
            return;
        }
    }
}

std::string output_under_cursor() {
    std::string json;
    if (run_capture({hyprctl_bin(), "monitors", "-j"}, json) != 0)
        return {};
    const auto monitors = parse_monitors(json);
    int        x        = 0;
    int        y        = 0;
    if (read_pointer(x, y)) {
        if (const auto* monitor = monitor_at(x, y, monitors))
            return monitor->name;
    }
    for (const auto& monitor : monitors) {
        if (monitor.focused)
            return monitor.name;
    }
    return monitors.empty() ? std::string{} : monitors.front().name;
}

PopupPlace place_popup(int prefer_x, int prefer_y, int width, int height, int parent_left, bool beside, const std::vector<Monitor>& monitors, const Monitor* pinned) {
    PopupPlace place;
    const Monitor* monitor = pinned ? pinned : monitor_at(prefer_x, prefer_y, monitors);
    int            x       = prefer_x;
    int            y       = prefer_y;
    if (beside && monitor && x + width > monitor->x + monitor->width - 8)
        x = parent_left - width - 6;
    if (!monitor) {
        place.global_x = x;
        place.global_y = y;
        place.local_x  = x;
        place.local_y  = y;
        return place;
    }
    if (x < monitor->x + 8)
        x = monitor->x + 8;
    if (y < monitor->y + 8)
        y = monitor->y + 8;
    if (x + width > monitor->x + monitor->width - 8)
        x = std::max(monitor->x + 8, monitor->x + monitor->width - width - 8);
    if (y + height > monitor->y + monitor->height - 8)
        y = std::max(monitor->y + 8, monitor->y + monitor->height - height - 8);
    place.global_x = x;
    place.global_y = y;
    place.local_x  = x - monitor->x;
    place.local_y  = y - monitor->y;
    return place;
}

CSharedPointer<CImageElement> image_for_png(const std::vector<uint8_t>& png, float side) {
    if (png.empty())
        return {};
    auto bytes = png;
    return CImageBuilder::begin()->data(std::move(bytes))->fitMode(IMAGE_FIT_MODE_CONTAIN)->sync(true)->size(box_size(side, side))->commence();
}

std::string window_meta(const Client& client) {
    const auto& klass = client.initial_class.empty() ? client.klass : client.initial_class;
    if (client.workspace.empty())
        return klass;
    if (klass.empty())
        return client.workspace;
    return klass + "  ·  " + client.workspace;
}

std::string lua_quote(const std::string& text) {
    std::string out = "\"";
    for (const char c : text) {
        if (c == '\\' || c == '"')
            out.push_back('\\');
        if (c == '\n') {
            out += "\\n";
            continue;
        }
        out.push_back(c);
    }
    out.push_back('"');
    return out;
}

void hypr_dispatch(const std::string& expression) {
    run_detached({hyprctl_bin(), "dispatch", expression});
}

std::string workspace_lua(const Placement& place) {
    const std::string name = place.workspace_name.empty() ? std::to_string(place.workspace) : place.workspace_name;
    return lua_quote(name);
}

void pull_window(const Placement& place, const std::string& address) {
    if (is_minimized_workspace(place.workspace_name))
        return;
    const std::string window = lua_quote("address:" + address);
    const std::string ws     = workspace_lua(place);
    // One eval so focus cannot run while the window is still on special:minimized.
    const std::string code = "hl.dispatch(hl.dsp.window.move({ workspace = " + ws + ", follow = false, window = " + window + " }))\n" +
                             "hl.dispatch(hl.dsp.focus({ window = " + window + " }))\n";
    run_detached({hyprctl_bin(), "eval", code});
}

CDynamicSize fill_auto() {
    return {CDynamicSize::HT_SIZE_PERCENT, CDynamicSize::HT_SIZE_AUTO, {1.F, 0.F}};
}

CHyprColor over_red() {
    return {0xEF / 255.F, 0x29 / 255.F, 0x29 / 255.F, 1.F};
}

class DeskUi {
  public:
    explicit DeskUi(bool open_menu, int listen_fd);
    void run();

  private:
    void open_menu_at_cursor();
    void close_menu();
    void rebuild_menu();
    void rebuild_flyout();
    void show_osd();
    void hide_osd();
    void tick_clock();
    void handle_command(DeskCommand command);
    void apply_volume(double level, bool unmute);
    void toggle_mute();
    void refresh_volume();
    void launch(const DesktopEntry& entry);
    void restore_client(const Client& client);
    void leave_categories();
    void close_client(const Client& client);
    void power(const std::string& action);
    void open_tray_menu(const TrayIcon& icon);
    void open_tray_layer(const std::vector<TrayMenuItem>& items, size_t level, int item_id, int prefer_x, int prefer_y, int parent_left, bool beside);
    void close_tray_from(size_t level);
    void queue_tray_hover(const TrayMenuItem& item, size_t level, int prefer_x, int prefer_y, int parent_left, bool open_child);
    void queue_dismiss_tray_tree();
    bool pointer_over_tray_tree();
    void show_icon_tip(const std::string& text);
    void close_icon_tip();
    void sync_volume_row();
    StatsText cached_stats();
    Volume read_volume() const;

    CSharedPointer<IBackend>              m_backend;
    CSharedPointer<CPalette>              m_palette;
    StatusTray                            m_tray;
    Volume                                m_volume;
    Placement                             m_place;
    std::vector<DesktopEntry>             m_apps;
    std::vector<Client>                   m_clients;
    StatsText                             m_stats;
    std::optional<CpuSample>              m_cpu;
    std::string                           m_search;
    std::string                           m_category;
    std::string                           m_category_label;
    bool                                  m_pinned       = false;
    bool                                  m_minimized    = true;
    bool                                  m_menu_open    = false;
    bool                                  m_adjusting    = false;
    int                                   m_poke         = -1;
    int                                   m_listen       = -1;
    CSharedPointer<IWindow>               m_menu;
    CSharedPointer<IWindow>               m_flyout;
    CSharedPointer<IWindow>               m_dismiss;
    CSharedPointer<IWindow>               m_osd;
    struct TrayLayer {
        CSharedPointer<IWindow> window;
        int                     gx      = 0;
        int                     gy      = 0;
        int                     width   = 0;
        int                     height  = 0;
        int                     item_id = -1;
    };
    std::vector<TrayLayer>                m_tray_layers;
    TrayIcon                              m_tray_popup_icon;
    TrayMenuItem                          m_tray_hover_item;
    size_t                                m_tray_hover_level       = 0;
    int                                   m_tray_hover_x           = 0;
    int                                   m_tray_hover_y           = 0;
    int                                   m_tray_hover_parent_left = 0;
    bool                                  m_tray_hover_open        = false;
    bool                                  m_tray_hover_valid       = false;
    bool                                  m_tray_hover_queued      = false;
    CSharedPointer<IWindow>               m_icon_tip;
    CAtomicSharedPointer<CTimer>          m_tip_timer;
    int                                   m_tip_gx = 0;
    int                                   m_tip_gy = 0;
    int                                   m_tip_w  = 0;
    int                                   m_tip_h  = 0;
    CSharedPointer<CColumnLayoutElement>  m_menu_layout;
    CSharedPointer<CTextboxElement>       m_search_box;
    CSharedPointer<CTextElement>          m_clock;
    CSharedPointer<CTextElement>          m_date;
    CSharedPointer<CTextElement>          m_cpu_text;
    CSharedPointer<CTextElement>          m_mem_text;
    CSharedPointer<CTextElement>          m_gpu_text;
    CSharedPointer<CTextElement>          m_net_text;
    CSharedPointer<CTextElement>          m_volume_readout;
    CSharedPointer<CSliderElement>        m_menu_slider;
    CSharedPointer<CButtonElement>        m_mute_button;
    CSharedPointer<CTextElement>          m_osd_label;
    CSharedPointer<CRectangleElement>     m_osd_track;
    CAtomicSharedPointer<CTimer>          m_osd_timer;
    std::string                           m_osd_port;
    bool                                  m_volume_paint = false;
    std::atomic<bool>                     m_stop{false};
    std::mutex                            m_stats_mu;
    std::thread                           m_volume_thread;
    std::thread                           m_stats_thread;
};

DeskUi::DeskUi(bool open_menu, int listen_fd) : m_backend(IBackend::create()), m_palette(m_backend->getPalette()), m_listen(listen_fd) {
    int pipes[2] = {-1, -1};
    if (pipe2(pipes, O_CLOEXEC | O_NONBLOCK) == 0)
        m_poke = pipes[0];
    m_volume = read_volume();
    m_apps   = load_desktop_entries();
    m_cpu    = read_cpu_sample();
    m_stats  = read_stats(std::nullopt);
    m_stats_thread = std::thread([this] {
        auto earlier = m_cpu;
        while (!m_stop.load()) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
            if (m_stop.load())
                break;
            auto now   = read_cpu_sample();
            auto stats = read_stats(earlier);
            earlier    = now;
            std::lock_guard lock(m_stats_mu);
            m_stats = std::move(stats);
            m_cpu   = now;
        }
    });
    if (m_tray.start() && m_tray.fd() >= 0) {
        m_backend->addFd(m_tray.fd(), [this] {
            const auto before = m_tray.generation();
            m_tray.process();
            if (m_menu_open && m_tray.generation() != before)
                m_backend->addIdle([this] { rebuild_menu(); });
        });
        m_backend->addTimer(std::chrono::seconds(1), [this](CAtomicSharedPointer<CTimer>, void*) { m_tray.announce(); }, nullptr);
    }
    if (m_poke >= 0) {
        m_backend->addFd(m_poke, [this] {
            char buffer[64];
            while (read(m_poke, buffer, sizeof(buffer)) > 0) {
            }
            refresh_volume();
        });
    }
    const int write_fd = pipes[1];
    m_volume_thread    = std::thread([this, write_fd] {
        Volume previous = m_volume;
        while (!m_stop.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            auto now = read_volume();
            if (!(now == previous)) {
                previous = now;
                if (write_fd >= 0)
                    (void)write(write_fd, "v", 1);
            }
        }
        if (write_fd >= 0)
            close(write_fd);
    });
    if (m_listen >= 0) {
        m_backend->addFd(m_listen, [this] {
            while (true) {
                const int client = accept4(m_listen, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
                if (client < 0)
                    break;
                char       buffer[64] = {};
                const auto got        = read(client, buffer, sizeof(buffer) - 1);
                close(client);
                if (got > 0)
                    handle_command(parse_command(buffer));
            }
        });
    }
    if (open_menu)
        m_backend->addIdle([this] { open_menu_at_cursor(); });
}

void DeskUi::handle_command(DeskCommand command) {
    if (command == DeskCommand::Open || (command == DeskCommand::Toggle && !m_menu_open))
        open_menu_at_cursor();
    else if (command == DeskCommand::Close || command == DeskCommand::Toggle)
        close_menu();
}

Volume DeskUi::read_volume() const {
    std::string text;
    run_capture({"wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"}, text);
    return parse_wpctl(text);
}

void DeskUi::refresh_volume() {
    auto now = read_volume();
    if (now == m_volume)
        return;
    m_volume = now;
    if (m_adjusting)
        return;
    if (m_menu_open)
        sync_volume_row();
    show_osd();
}

void DeskUi::sync_volume_row() {
    m_volume_paint = true;
    if (m_menu_slider)
        m_menu_slider->rebuild()->val(static_cast<float>(m_volume.valid && !m_volume.muted ? m_volume.level : 0.0))->commence();
    if (m_volume_readout)
        m_volume_readout->setText(menu_volume_percent(m_volume));
    if (m_mute_button)
        m_mute_button->setLabel(menu_volume_caption(m_volume));
    m_volume_paint = false;
}

StatsText DeskUi::cached_stats() {
    std::lock_guard lock(m_stats_mu);
    return m_stats;
}

void DeskUi::apply_volume(double level, bool unmute) {
    m_adjusting = true;
    std::ostringstream number;
    number.setf(std::ios::fixed);
    number.precision(3);
    number << snap_volume(level);
    std::string ignored;
    run_capture({"wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", number.str()}, ignored);
    if (unmute)
        run_capture({"wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0"}, ignored);
    m_volume       = read_volume();
    m_adjusting    = false;
}

void DeskUi::toggle_mute() {
    m_adjusting = true;
    std::string ignored;
    run_capture({"wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"}, ignored);
    m_volume    = read_volume();
    m_adjusting = false;
    if (m_menu_open)
        sync_volume_row();
}

void DeskUi::show_osd() {
    constexpr float osd_h      = 220.F;
    constexpr float track_h    = 168.F;
    constexpr float fill_inset = 3.F;
    constexpr float panel_pad  = 8.F;

    const std::string label  = osd_label(m_volume);
    const std::string family = m_palette->m_vars.fontFamily;
    const float       pt     = static_cast<float>(m_palette->m_vars.smallFontSize);
    const LabelExtent extent = measure_label(label, family, pt);
    // Lock the track to the "100%" label so it does not resize as the
    // percent string gains or loses a digit.
    const float track_w = measure_label("100%", family, pt).width;

    // One layer until the cursor's monitor changes. Close the old surface
    // before opening another, or the compositor keeps both.
    const std::string port = output_under_cursor();
    if (m_osd && port != m_osd_port) {
        if (m_osd_timer)
            m_osd_timer->cancel();
        m_osd->close();
        m_osd.reset();
        m_osd_label.reset();
        m_osd_track.reset();
    }
    if (!m_osd) {
        float widest = track_w;
        for (const char* sample : {"112.5%", "147.5%", "72.5%", "150%", "MUTE", "--%"})
            widest = std::max(widest, measure_label(sample, family, pt).width);
        const float osd_w = widest + (panel_pad * 2.F);
        auto background = CRectangleBuilder::begin()
                              ->color([this] { return m_palette->m_colors.background; })
                              ->borderColor([this] { return volume_overdrive(m_volume) ? over_red() : m_palette->m_colors.alternateBase; })
                              ->borderThickness(1)
                              ->rounding(m_palette->m_vars.bigRounding)
                              ->size(percent_box(1, 1))
                              ->commence();
        auto column = CColumnLayoutBuilder::begin()->gap(6)->size(percent_box(1, 1))->commence();
        column->setMargin(panel_pad);
        m_osd_label = CTextBuilder::begin()
                          ->text(std::string{label})
                          ->align(HT_FONT_ALIGN_CENTER)
                          ->fontSize({CFontSize::HT_FONT_SMALL, 1.F})
                          ->fontFamily(std::string{family})
                          ->color([this] { return volume_overdrive(m_volume) ? over_red() : m_palette->m_colors.text; })
                          ->async(false)
                          ->size(box_size(extent.width, extent.height))
                          ->commence();
        m_osd_label->setPositionFlag(IElement::HT_POSITION_FLAG_HCENTER, true);
        m_osd_track = CRectangleBuilder::begin()
                          ->color([this] { return m_palette->m_colors.base; })
                          ->borderColor([this] { return m_palette->m_colors.alternateBase; })
                          ->borderThickness(1)
                          ->rounding(8)
                          ->size(box_size(track_w, track_h))
                          ->commence();
        column->addChild(m_osd_label);
        column->addChild(m_osd_track);
        background->addChild(column);
        auto builder = CWindowBuilder::begin()
                           ->type(HT_WINDOW_LAYER)
                           ->appClass("hyprdesk-osd")
                           ->appTitle("Volume")
                           ->preferredSize({osd_w, osd_h})
                           ->anchor(kAnchorTopLeft)
                           ->marginTopLeft({24, 24})
                           ->exclusiveZone(-1)
                           ->layer(3)
                           ->kbInteractive(0);
        bind_output(builder, m_backend.get(), port);
        m_osd      = builder->commence();
        m_osd_port = port;
        m_osd->m_rootElement->addChild(background);
    }

    m_osd_label->rebuild()->text(std::string{label})->size(box_size(extent.width, extent.height))->commence();
    m_osd_track->rebuild()->size(box_size(track_w, track_h))->commence();
    m_osd_track->clearChildren();
    const float fill    = static_cast<float>(volume_fill(m_volume));
    const float inner_w = std::max(0.F, track_w - (2.F * fill_inset));
    const float inner_h = std::max(0.F, track_h - (2.F * fill_inset));
    const float bar_h   = std::round(std::min(inner_h, std::max(0.F, fill * inner_h)));
    if (bar_h >= 1.F && inner_w >= 1.F) {
        auto bar = CRectangleBuilder::begin()
                       ->color([this] { return volume_overdrive(m_volume) ? over_red() : m_palette->m_colors.accent; })
                       ->rounding(5)
                       ->size(box_size(inner_w, bar_h))
                       ->commence();
        bar->setPositionMode(IElement::HT_POSITION_ABSOLUTE);
        bar->setPositionFlag(IElement::HT_POSITION_FLAG_LEFT, true);
        bar->setPositionFlag(IElement::HT_POSITION_FLAG_BOTTOM, true);
        bar->setAbsolutePosition({fill_inset, -fill_inset});
        m_osd_track->addChild(bar);
    }
    m_osd->open();
    if (m_osd_timer)
        m_osd_timer->cancel();
    m_osd_timer = m_backend->addTimer(std::chrono::milliseconds(5000), [this](CAtomicSharedPointer<CTimer>, void*) { hide_osd(); }, nullptr);
}

void DeskUi::hide_osd() {
    if (m_osd)
        m_osd->close();
}

void DeskUi::close_menu() {
    m_menu_open         = false;
    m_tray_hover_queued = false;
    m_tray_hover_valid  = false;
    m_pinned            = false;
    m_category.clear();
    if (m_tip_timer)
        m_tip_timer->cancel();
    close_icon_tip();
    close_tray_from(0);
    if (m_menu)
        m_menu->close();
    if (m_flyout)
        m_flyout->close();
    if (m_dismiss)
        m_dismiss->close();
}

void DeskUi::power(const std::string& action) {
    const char* home = std::getenv("HOME");
    if (!home)
        return;
    run_detached({std::string(home) + "/.config/hypr/scripts/session-control.sh", action});
    m_backend->addIdle([this] { close_menu(); });
}

void DeskUi::restore_client(const Client& client) {
    if (!safe_window_address(client.address))
        return;
    pull_window(m_place, client.address);
    m_backend->addIdle([this] { close_menu(); });
}

void DeskUi::leave_categories() {
    if (m_pinned || !m_search.empty())
        return;
    m_category.clear();
    m_category_label.clear();
    if (m_flyout)
        m_flyout->close();
}

void DeskUi::close_client(const Client& client) {
    if (!safe_window_address(client.address))
        return;
    hypr_dispatch("hl.dsp.window.close({ window = " + lua_quote("address:" + client.address) + " })");
    m_backend->addIdle([this] { rebuild_menu(); });
}

void DeskUi::launch(const DesktopEntry& entry) {
    std::string clients_json;
    run_capture({hyprctl_bin(), "clients", "-j"}, clients_json);
    const auto clients = parse_clients(clients_json);
    const auto needles = entry_needles(entry);
    for (const auto& client : clients) {
        const auto& klass = client.initial_class.empty() ? client.klass : client.initial_class;
        for (const auto& needle : needles) {
            const bool title_hit = needle.size() >= 6 && class_matches_needle(client.title, needle);
            if (!class_matches_needle(klass, needle) && !title_hit)
                continue;
            if (!safe_window_address(client.address))
                continue;
            pull_window(m_place, client.address);
            m_backend->addIdle([this] { close_menu(); });
            return;
        }
    }
    const std::string command = strip_exec_field_codes(entry.exec);
    if (command.find_first_not_of(" \t") == std::string::npos)
        return;
    if (is_minimized_workspace(m_place.workspace_name))
        return;
    const std::string ws = workspace_lua(m_place);
    const std::string code = "hl.dispatch(hl.dsp.focus({ workspace = " + ws + " }))\n" +
                             "hl.dispatch(hl.dsp.exec_cmd(" + lua_quote(command) + ", { workspace = " + ws + " }))\n";
    run_detached({hyprctl_bin(), "eval", code});
    m_backend->addIdle([this] { close_menu(); });
}

void DeskUi::rebuild_flyout() {
    if (m_flyout)
        m_flyout->close();
    const bool searching = !m_search.empty();
    if (!searching && m_category.empty())
        return;
    const auto apps = filter_apps(m_apps, searching ? "*" : m_category, m_search);
    auto background = CRectangleBuilder::begin()
                          ->color([this] { return m_palette->m_colors.background; })
                          ->borderColor([this] { return m_palette->m_colors.alternateBase; })
                          ->borderThickness(1)
                          ->rounding(m_palette->m_vars.bigRounding)
                          ->size(percent_box(1, 1))
                          ->commence();
    auto column = CColumnLayoutBuilder::begin()->gap(4)->size(percent_box(1, 1))->commence();
    column->setMargin(8);
    const std::string title = searching ? "Search" : m_category_label;
    column->addChild(CTextBuilder::begin()->text(std::string{title})->fontSize({CFontSize::HT_FONT_SMALL, 1.F})->size(bar_size(1, 16))->commence());
    auto scroll = CScrollAreaBuilder::begin()->scrollY(true)->size(percent_box(1, 1))->commence();
    scroll->setGrow(true);
    auto list = CColumnLayoutBuilder::begin()->gap(2)->size(fill_auto())->commence();
    if (apps.empty()) {
        list->addChild(CTextBuilder::begin()->text("No apps")->size(bar_size(1, 24))->commence());
    }
    size_t shown = 0;
    for (const auto& app : apps) {
        if (shown++ == 400)
            break;
        auto button = CButtonBuilder::begin()
                          ->label("")
                          ->noBorder(true)
                          ->size(bar_size(1, 34))
                          ->onMainClick([this, app](CSharedPointer<CButtonElement>) { launch(app); })
                          ->onRightClick([this, app](CSharedPointer<CButtonElement>) {
                              run_detached({"code", "--", app.path});
                              m_backend->addIdle([this] { close_menu(); });
                          })
                          ->commence();
        auto line = CRowLayoutBuilder::begin()->gap(8)->size(percent_box(1, 1))->commence();
        line->setMargin(4);
        if (auto icon = image_for_name(m_backend.get(), app.icon, "", 20.F, false))
            line->addChild(icon);
        auto name = CTextBuilder::begin()
                        ->text(std::string{app.name})
                        ->async(false)
                        ->align(HT_FONT_ALIGN_LEFT)
                        ->fontSize({CFontSize::HT_FONT_TEXT, 1.F})
                        ->size({CDynamicSize::HT_SIZE_ABSOLUTE, CDynamicSize::HT_SIZE_PERCENT, {8.F, 1.F}})
                        ->commence();
        name->setGrow(true, false);
        line->addChild(name);
        button->addChild(line);
        list->addChild(button);
    }
    scroll->addChild(list);
    column->addChild(scroll);
    background->addChild(column);
    const int count   = apps.empty() ? 1 : static_cast<int>(std::min(apps.size(), static_cast<size_t>(400)));
    const int natural = 16 + 8 + 4 + count * 36 + 16;
    const int height  = std::min(std::max(80, m_place.menu_h), std::max(80, natural));
    auto      builder = CWindowBuilder::begin()
                       ->type(HT_WINDOW_LAYER)
                       ->appClass("hyprdesk-flyout")
                       ->appTitle("Apps")
                       ->preferredSize({static_cast<double>(m_place.flyout_w), static_cast<double>(height)})
                       ->anchor(kAnchorTopLeft)
                       ->marginTopLeft({static_cast<double>(m_place.flyout_left), static_cast<double>(m_place.menu_top)})
                       ->exclusiveZone(-1)
                       ->layer(3)
                       ->kbInteractive(0);
    bind_output(builder, m_backend.get(), m_place.monitor_name);
    m_flyout = builder->commence();
    m_flyout->m_rootElement->addChild(background);
    m_flyout->open();
}

void DeskUi::rebuild_menu() {
    if (!m_menu)
        return;
    bool        show_all = false;
    const auto  windows  = windows_for_menu(m_clients, m_minimized, show_all);
    if (show_all)
        m_minimized = false;
    m_menu_slider.reset();
    m_volume_readout.reset();
    m_mute_button.reset();
    m_menu_layout->clearChildren();
    auto upper = CColumnLayoutBuilder::begin()->gap(kMenuCategoryGap)->size(fill_auto())->commence();
    auto rule  = [this] {
        return CRectangleBuilder::begin()
            ->color([this] {
                auto color = m_palette->m_colors.text;
                color.a    = 0.35F;
                return color;
            })
            ->size(bar_size(1, 2))
            ->commence();
    };
    auto below_categories = [this](const Vector2D&) {
        leave_categories();
        queue_dismiss_tray_tree();
    };
    m_search_box = CTextboxBuilder::begin()
                       ->placeholder("Search apps…")
                       ->defaultText(std::string{m_search})
                       ->multiline(false)
                       ->onTextEdited([this](CSharedPointer<CTextboxElement>, const std::string& text) {
                           m_search = text;
                           if (!m_search.empty()) {
                               m_category       = "*";
                               m_category_label = "Search";
                           }
                           rebuild_flyout();
                       })
                       ->size(bar_size(1, kMenuSearchRow))
                       ->commence();
    upper->addChild(m_search_box);

    const struct {
        const char* label;
        const char* cat;
    } categories[] = {
        {"All", "*"},       {"Accessories", "Utility"}, {"Development", "Development"}, {"Games", "Game"},     {"Graphics", "Graphics"},
        {"Internet", "Network"}, {"Multimedia", "AudioVideo"}, {"Office", "Office"}, {"Settings", "Settings"}, {"System", "System"},
    };
    static_assert(sizeof(categories) / sizeof(categories[0]) == static_cast<size_t>(kMenuCategoryCount));
    for (const auto& category : categories) {
        auto button = CButtonBuilder::begin()
                          ->label(std::string{category.label})
                          ->noBorder(true)
                          ->fontSize({CFontSize::HT_FONT_TEXT, 1.F})
                          ->size(bar_size(1, kMenuCategoryRow))
                          ->onMainClick([this, category](CSharedPointer<CButtonElement>) {
                              if (m_pinned && m_category == category.cat) {
                                  m_pinned = false;
                                  m_category.clear();
                                  m_category_label.clear();
                              } else {
                                  m_pinned         = true;
                                  m_category       = category.cat;
                                  m_category_label = category.label;
                                  m_search.clear();
                              }
                              m_backend->addIdle([this] {
                                  rebuild_menu();
                                  rebuild_flyout();
                              });
                          })
                          ->commence();
        button->setReceivesMouse(true);
        button->setMouseEnter([this, category](const Vector2D&) {
            if (m_pinned || !m_search.empty())
                return;
            if (m_category == category.cat && m_flyout)
                return;
            m_category       = category.cat;
            m_category_label = category.label;
            rebuild_flyout();
        });
        upper->addChild(button);
    }

    const auto bands    = menu_bands(m_place.menu_h, static_cast<int>(windows.size()));
    auto       scroller = CScrollAreaBuilder::begin()->scrollY(true)->size(bar_size(1, bands.top))->commence();
    scroller->setGrow(false, true);
    scroller->addChild(upper);
    m_menu_layout->addChild(scroller);
    m_menu_layout->addChild(rule());
    auto header = CRowLayoutBuilder::begin()->gap(8)->size(bar_size(1, 28))->commence();
    header->setReceivesMouse(true);
    header->setMouseEnter(below_categories);
    auto header_label = CTextBuilder::begin()
                            ->text(m_minimized ? std::string{"Minimized"} : std::string{"Windows"})
                            ->fontSize({CFontSize::HT_FONT_SMALL, 1.F})
                            ->size(box_size(120, 22))
                            ->commence();
    header_label->setGrow(true, false);
    header->addChild(header_label);
    auto filter_button = CButtonBuilder::begin()
                             ->label(m_minimized ? std::string{"All"} : std::string{"Min"})
                             ->ellipsize(true)
                             ->noBorder(true)
                             ->size(box_size(48, 26))
                             ->onMainClick([this](CSharedPointer<CButtonElement>) {
                                 m_minimized = !m_minimized;
                                 m_backend->addIdle([this] { rebuild_menu(); });
                             })
                             ->commence();
    filter_button->setReceivesMouse(true);
    filter_button->setMouseEnter(below_categories);
    header->addChild(filter_button);
    auto refresh_button = CButtonBuilder::begin()
                              ->label("Refresh")
                              ->ellipsize(true)
                              ->noBorder(true)
                              ->fontSize({CFontSize::HT_FONT_SMALL, 1.F})
                              ->size(box_size(96, 26))
                              ->onMainClick([this](CSharedPointer<CButtonElement>) {
                             std::string json;
                             run_capture({hyprctl_bin(), "clients", "-j"}, json);
                             m_clients = parse_clients(json);
                             m_backend->addIdle([this] { rebuild_menu(); });
                         })
                         ->commence();
    refresh_button->setReceivesMouse(true);
    refresh_button->setMouseEnter(below_categories);
    header->addChild(refresh_button);
    m_menu_layout->addChild(header);

    auto window_scroll = CScrollAreaBuilder::begin()->scrollY(true)->size(bar_size(1, bands.windows))->commence();
    window_scroll->setReceivesMouse(true);
    window_scroll->setMouseEnter(below_categories);
    auto window_list   = CColumnLayoutBuilder::begin()->gap(kMenuWindowGap)->size(fill_auto())->commence();
    if (windows.empty()) {
        window_list->addChild(CTextBuilder::begin()->text(m_minimized ? std::string{"No minimized windows"} : std::string{"No windows"})->async(false)->size(bar_size(1, kMenuWindowEmpty))->commence());
    }
    for (const auto& client : windows) {
        const auto title = client.title.empty() ? std::string{"(no title)"} : client.title;
        const auto meta  = window_meta(client);
        auto row = CRectangleBuilder::begin()->color([] { return CHyprColor{0, 0, 0, 0}; })->rounding(m_palette->m_vars.smallRounding)->size(bar_size(1, kMenuWindowRow))->commence();
        row->setReceivesMouse(true);
        row->setMouseEnter(below_categories);
        row->setMouseButton([this, client](Input::eMouseButton button, bool down) {
            if (!down)
                return;
            if (button == Input::MOUSE_BUTTON_RIGHT)
                close_client(client);
            else if (button == Input::MOUSE_BUTTON_LEFT)
                restore_client(client);
        });
        auto lines = CColumnLayoutBuilder::begin()->gap(0)->size(percent_box(1, 1))->commence();
        lines->setMargin(4);
        lines->addChild(CTextBuilder::begin()
                            ->text(std::string{title})
                            ->async(false)
                            ->size(bar_size(1, 18))
                            ->commence());
        if (!meta.empty()) {
            lines->addChild(CTextBuilder::begin()
                                ->text(std::string{meta})
                                ->async(false)
                                ->fontSize({CFontSize::HT_FONT_SMALL, 1.F})
                                ->color([this] { return m_palette->m_colors.text; })
                                ->size(bar_size(1, 14))
                                ->commence());
        }
        row->addChild(lines);
        window_list->addChild(row);
    }
    window_scroll->addChild(window_list);
    m_menu_layout->addChild(window_scroll);

    m_tray.refresh();
    {
        auto tray_row = CRowLayoutBuilder::begin()->gap(4)->size(bar_size(1, 28))->commence();
        for (const auto& icon : m_tray.items()) {
            const auto label = !icon.title.empty() ? icon.title : (!icon.id.empty() ? icon.id : icon.service);
            auto picture = image_for_name(m_backend.get(), icon.icon, icon.icon_theme, 22.F, true);
            if (!picture)
                picture = image_for_png(icon.icon_png, 22.F);
            std::string shown;
            if (!picture && !label.empty())
                shown = label.substr(0, std::min<size_t>(2, label.size()));
            auto button = CButtonBuilder::begin()
                              ->label(std::move(shown))
                              ->ellipsize(true)
                              ->noBorder(true)
                              ->size(box_size(28, 28))
                              ->onMainClick([this, icon](CSharedPointer<CButtonElement>) {
                                  leave_categories();
                                  if (icon.item_is_menu) {
                                      m_backend->addIdle([this, icon] { open_tray_menu(icon); });
                                      return;
                                  }
                                  int x = 0;
                                  int y = 0;
                                  read_pointer(x, y);
                                  m_tray.activate(icon, x, y);
                              })
                              ->onRightClick([this, icon](CSharedPointer<CButtonElement>) {
                                  leave_categories();
                                  m_backend->addIdle([this, icon] { open_tray_menu(icon); });
                              })
                              ->commence();
            button->setReceivesMouse(true);
            button->setMouseEnter([this, label, below_categories](const Vector2D& at) {
                below_categories(at);
                if (m_tip_timer)
                    m_tip_timer->cancel();
                m_tip_timer = m_backend->addTimer(std::chrono::milliseconds(500), [this, label](CAtomicSharedPointer<CTimer>, void*) { show_icon_tip(label); }, nullptr);
            });
            button->setMouseLeave([this]() {
                if (m_tip_timer)
                    m_tip_timer->cancel();
                m_backend->addIdle([this] {
                    int x = 0;
                    int y = 0;
                    if (m_icon_tip && read_pointer(x, y) &&
                        (box_contains(x, y, m_tip_gx, m_tip_gy, m_tip_w, m_tip_h, 4) ||
                         box_contains(x, y, m_tip_gx, m_tip_gy + m_tip_h, m_tip_w, 36, 0)))
                        return;
                    close_icon_tip();
                });
            });
            button->setMouseButton([this, icon](Input::eMouseButton button, bool down) {
                if (!down || button != Input::MOUSE_BUTTON_MIDDLE)
                    return;
                int x = 0;
                int y = 0;
                read_pointer(x, y);
                m_tray.secondary(icon, x, y);
            });
            button->setMouseAxis([this, icon](Input::eAxisAxis axis, float delta) {
                if (axis != Input::AXIS_AXIS_VERTICAL || delta == 0.F)
                    return;
                m_tray.scroll(icon, delta > 0 ? 1 : -1, "vertical");
            });
            if (picture) {
                picture->setPositionMode(IElement::HT_POSITION_ABSOLUTE);
                picture->setPositionFlag(IElement::HT_POSITION_FLAG_CENTER, true);
                button->addChild(picture);
            }
            tray_row->addChild(button);
        }
        tray_row->setReceivesMouse(true);
        tray_row->setMouseEnter(below_categories);
        m_menu_layout->addChild(rule());
        m_menu_layout->addChild(tray_row);
    }

    m_menu_layout->addChild(rule());
    auto volume_row = CRowLayoutBuilder::begin()->gap(8)->size(bar_size(1, 28))->commence();
    volume_row->setReceivesMouse(true);
    volume_row->setMouseEnter(below_categories);
    auto mute_button = CButtonBuilder::begin()
                           ->label(menu_volume_caption(m_volume))
                           ->noBorder(true)
                           ->size(box_size(56, 28))
                           ->onMainClick([this](CSharedPointer<CButtonElement>) { toggle_mute(); })
                           ->commence();
    mute_button->setReceivesMouse(true);
    mute_button->setMouseEnter(below_categories);
    m_mute_button = mute_button;
    volume_row->addChild(mute_button);
    auto slider = CSliderBuilder::begin()
                      ->min(0)
                      ->max(1.5F)
                      ->val(static_cast<float>(m_volume.muted ? 0 : m_volume.level))
                      ->size(box_size(80, 28))
                      ->onChanged([this](CSharedPointer<CSliderElement>, float value) {
                          if (m_volume_paint)
                              return;
                          const double snapped = snap_volume(value);
                          if (std::abs(snapped - m_volume.level) < 0.001 && !m_volume.muted)
                              return;
                          apply_volume(snapped, true);
                          sync_volume_row();
                      })
                      ->commence();
    slider->setGrow(true, false);
    slider->setReceivesMouse(true);
    slider->setMouseEnter(below_categories);
    m_menu_slider = slider;
    slider->setMouseAxis([this](Input::eAxisAxis axis, float delta) {
        if (axis != Input::AXIS_AXIS_VERTICAL || delta == 0.F)
            return;
        const double dir = delta < 0.F ? 1.0 : -1.0;
        apply_volume(snap_volume(m_volume.level + (dir * 0.025)), true);
        sync_volume_row();
    });
    volume_row->addChild(slider);
    m_volume_readout = CTextBuilder::begin()
                           ->text(menu_volume_percent(m_volume))
                           ->align(HT_FONT_ALIGN_RIGHT)
                           ->async(false)
                           ->color([this] { return volume_overdrive(m_volume) ? over_red() : m_palette->m_colors.text; })
                           ->size(box_size(56, 28))
                           ->commence();
    volume_row->addChild(m_volume_readout);
    m_menu_layout->addChild(volume_row);

    m_stats = cached_stats();
    const std::string family = m_palette->m_vars.fontFamily;
    const float       pt     = static_cast<float>(m_palette->m_vars.fontSize);
    auto status_row = CRowLayoutBuilder::begin()->gap(10)->size(bar_size(1, 22))->commence();
    status_row->setReceivesMouse(true);
    status_row->setMouseEnter(below_categories);
    auto add_status = [&](const std::string& text, const std::string& widest, CSharedPointer<CTextElement>& slot) {
        const float width = std::max(1.F, measure_label(widest, family, pt).width);
        slot = CTextBuilder::begin()->text(std::string{text})->async(false)->align(HT_FONT_ALIGN_LEFT)->size(box_size(width, 22))->commence();
        status_row->addChild(slot);
    };
    add_status(m_stats.cpu, m_stats.cpu_max, m_cpu_text);
    add_status(m_stats.mem, m_stats.mem_max, m_mem_text);
    add_status(m_stats.gpu, m_stats.gpu_max, m_gpu_text);
    add_status(m_stats.net, m_stats.net_max, m_net_text);
    m_menu_layout->addChild(rule());
    m_clock = CTextBuilder::begin()
                  ->text(std::string{m_stats.clock})
                  ->async(false)
                  ->fontSize({CFontSize::HT_FONT_H1, 1.F})
                  ->color([this] { return m_palette->m_colors.accent; })
                  ->size(bar_size(1, 36))
                  ->commence();
    m_date = CTextBuilder::begin()
                 ->text(std::string{m_stats.date})
                 ->async(false)
                 ->fontSize({CFontSize::HT_FONT_H1, 1.F})
                 ->color([this] { return m_palette->m_colors.accent; })
                 ->size(bar_size(1, 36))
                 ->commence();
    m_menu_layout->addChild(status_row);
    m_menu_layout->addChild(m_clock);
    m_menu_layout->addChild(m_date);

    auto power_row = CRowLayoutBuilder::begin()->gap(4)->size(bar_size(1, 40))->commence();
    power_row->setReceivesMouse(true);
    power_row->setMouseEnter(below_categories);
    const float power_w = std::max(64.F, std::floor((std::max(280.F, static_cast<float>(m_place.menu_w) - 36.F)) / 5.F));
    for (const auto& action : {"lock", "logout", "suspend", "reboot", "shutdown"}) {
        auto button = CButtonBuilder::begin()
                          ->label(std::string{action})
                          ->ellipsize(true)
                          ->noBorder(true)
                          ->size(box_size(power_w, 32))
                          ->onMainClick([this, action](CSharedPointer<CButtonElement>) { power(action); })
                          ->commence();
        button->setReceivesMouse(true);
        button->setMouseEnter(below_categories);
        power_row->addChild(button);
    }
    m_menu_layout->addChild(rule());
    m_menu_layout->addChild(power_row);
    if (m_search_box)
        m_search_box->focus();
}

void DeskUi::open_menu_at_cursor() {
    std::string cursor;
    std::string monitors_json;
    std::string clients_json;
    run_capture({hyprctl_bin(), "cursorpos"}, cursor);
    run_capture({hyprctl_bin(), "monitors", "-j"}, monitors_json);
    run_capture({hyprctl_bin(), "clients", "-j"}, clients_json);
    int x = 8;
    int y = 8;
    if (!cursor.empty())
        parse_cursor_pos(cursor, x, y);
    m_place = place_menu(x, y, parse_monitors(monitors_json), menu_height_for(kMenuWindowCap));
    m_stats = cached_stats();
    m_tray.announce();
    const float status_w = status_fields_width(m_stats, m_palette->m_vars.fontFamily, static_cast<float>(m_palette->m_vars.fontSize)) + 36.F;
    fit_menu_width(m_place, static_cast<int>(std::ceil(status_w)));
    m_clients          = parse_clients(clients_json);
    m_apps             = load_desktop_entries();
    m_menu_open        = true;
    m_search.clear();
    m_category       = "*";
    m_category_label = "All";
    m_pinned         = false;

    if (m_dismiss)
        m_dismiss->close();
    auto dismiss_rect = CRectangleBuilder::begin()->color([] { return CHyprColor{0, 0, 0, 0.01F}; })->size(percent_box(1, 1))->commence();
    dismiss_rect->setReceivesMouse(true);
    dismiss_rect->setMouseButton([this](Input::eMouseButton, bool down) {
        if (down)
            m_backend->addIdle([this] { close_menu(); });
    });
    auto dismiss = CWindowBuilder::begin()
                       ->type(HT_WINDOW_LAYER)
                       ->appClass("hyprdesk-dismiss")
                       ->preferredSize({static_cast<double>(m_place.monitor_w), static_cast<double>(m_place.monitor_h)})
                       ->anchor(kAnchorAll)
                       ->exclusiveZone(-1)
                       ->layer(2)
                       ->kbInteractive(0);
    bind_output(dismiss, m_backend.get(), m_place.monitor_name);
    m_dismiss = dismiss->commence();
    m_dismiss->m_rootElement->addChild(dismiss_rect);
    m_dismiss->open();

    if (m_menu)
        m_menu->close();
    auto background = CRectangleBuilder::begin()
                          ->color([this] { return m_palette->m_colors.background; })
                          ->borderColor([this] { return m_palette->m_colors.alternateBase; })
                          ->borderThickness(1)
                          ->rounding(m_palette->m_vars.bigRounding)
                          ->size(percent_box(1, 1))
                          ->commence();
    m_menu_layout = CColumnLayoutBuilder::begin()->gap(6)->size(percent_box(1, 1))->commence();
    m_menu_layout->setMargin(10);
    background->addChild(m_menu_layout);
    auto menu = CWindowBuilder::begin()
                    ->type(HT_WINDOW_LAYER)
                    ->appClass("hyprdesk")
                    ->appTitle("Desk")
                    ->preferredSize({static_cast<double>(m_place.menu_w), static_cast<double>(m_place.menu_h)})
                    ->anchor(kAnchorTopLeft)
                    ->marginTopLeft({static_cast<double>(m_place.menu_left), static_cast<double>(m_place.menu_top)})
                    ->exclusiveZone(-1)
                    ->layer(3)
                    ->kbInteractive(2);
    bind_output(menu, m_backend.get(), m_place.monitor_name);
    m_menu = menu->commence();
    m_menu->m_rootElement->addChild(background);
    m_menu->m_events.keyboardKey.listenStatic([this](Input::SKeyboardKeyEvent event) {
        if (event.down && !event.repeat && event.xkbKeysym == kEscape)
            close_menu();
    });
    rebuild_menu();
    rebuild_flyout();
    m_menu->open();
    tick_clock();
}

void DeskUi::close_icon_tip() {
    if (m_icon_tip)
        m_icon_tip->close();
    m_icon_tip.reset();
}

void DeskUi::show_icon_tip(const std::string& text) {
    close_icon_tip();
    if (!m_menu_open || text.empty())
        return;
    const float width  = std::max(24.F, measure_label(text, m_palette->m_vars.fontFamily, static_cast<float>(m_palette->m_vars.fontSize)).width + 16.F);
    const int   tip_w  = static_cast<int>(std::ceil(width));
    const int   tip_h  = 28;
    int         x      = 8;
    int         y      = 8;
    read_pointer(x, y);
    std::string monitors_json;
    run_capture({hyprctl_bin(), "monitors", "-j"}, monitors_json);
    const auto monitors = parse_monitors(monitors_json);
    const auto place    = place_popup(x, y - tip_h - 8, tip_w, tip_h, 0, false, monitors, named_monitor(monitors, m_place.monitor_name));
    m_tip_gx         = place.global_x;
    m_tip_gy         = place.global_y;
    m_tip_w          = tip_w;
    m_tip_h          = tip_h;
    auto background  = CRectangleBuilder::begin()
                          ->color([this] { return m_palette->m_colors.base; })
                          ->borderColor([this] { return m_palette->m_colors.alternateBase; })
                          ->borderThickness(1)
                          ->rounding(m_palette->m_vars.smallRounding)
                          ->size(percent_box(1, 1))
                          ->commence();
    background->setReceivesMouse(true);
    // The toolkit tooltip closes itself inside mouseLeave and frees the window
    // that is still handling the pointer. Close this label on the next idle.
    background->setMouseLeave([this]() {
        m_backend->addIdle([this] {
            int px = 0;
            int py = 0;
            if (read_pointer(px, py) && box_contains(px, py, m_tip_gx, m_tip_gy, m_tip_w, m_tip_h, 4))
                return;
            close_icon_tip();
        });
    });
    auto label = CTextBuilder::begin()->text(std::string{text})->async(false)->align(HT_FONT_ALIGN_CENTER)->size(percent_box(1, 1))->commence();
    background->addChild(label);
    auto tip = CWindowBuilder::begin()
                   ->type(HT_WINDOW_LAYER)
                   ->appClass("hyprdesk-tip")
                   ->appTitle("Icon")
                   ->preferredSize({static_cast<double>(tip_w), static_cast<double>(tip_h)})
                   ->anchor(kAnchorTopLeft)
                   ->marginTopLeft({static_cast<double>(place.local_x), static_cast<double>(place.local_y)})
                   ->exclusiveZone(-1)
                   ->layer(3)
                   ->kbInteractive(0);
    bind_output(tip, m_backend.get(), m_place.monitor_name);
    m_icon_tip = tip->commence();
    m_icon_tip->m_rootElement->addChild(background);
    m_icon_tip->open();
}

void DeskUi::close_tray_from(size_t level) {
    while (m_tray_layers.size() > level) {
        if (m_tray_layers.back().window)
            m_tray_layers.back().window->close();
        m_tray_layers.pop_back();
    }
}

bool DeskUi::pointer_over_tray_tree() {
    int x = 0;
    int y = 0;
    if (!read_pointer(x, y))
        return false;
    for (const auto& layer : m_tray_layers) {
        if (box_contains(x, y, layer.gx, layer.gy, layer.width, layer.height, 12))
            return true;
    }
    return false;
}

void DeskUi::queue_dismiss_tray_tree() {
    if (m_tray_layers.empty())
        return;
    m_backend->addIdle([this] {
        if (!m_menu_open)
            return;
        if (pointer_over_tray_tree())
            return;
        close_tray_from(0);
    });
}

void DeskUi::queue_tray_hover(const TrayMenuItem& item, size_t level, int prefer_x, int prefer_y, int parent_left, bool open_child) {
    if (!m_menu_open)
        return;
    m_tray_hover_item        = item;
    m_tray_hover_level       = level;
    m_tray_hover_x           = prefer_x;
    m_tray_hover_y           = prefer_y;
    m_tray_hover_parent_left = parent_left;
    m_tray_hover_open        = open_child;
    m_tray_hover_valid       = true;
    if (m_tray_hover_queued)
        return;
    m_tray_hover_queued = true;
    m_backend->addIdle([this] {
        m_tray_hover_queued = false;
        if (!m_menu_open || !m_tray_hover_valid)
            return;
        const bool open_child  = m_tray_hover_open;
        const auto item        = m_tray_hover_item;
        const auto level       = m_tray_hover_level;
        const int  prefer_x    = m_tray_hover_x;
        const int  prefer_y    = m_tray_hover_y;
        const int  parent_left = m_tray_hover_parent_left;
        m_tray_hover_valid     = false;
        if (!open_child) {
            close_tray_from(level + 1);
            return;
        }
        if (level + 1 < m_tray_layers.size() && m_tray_layers[level + 1].item_id == item.id)
            return;
        auto kids = item.children.empty() ? m_tray.submenu_items(m_tray_popup_icon, item.id) : item.children;
        close_tray_from(level + 1);
        if (kids.empty())
            return;
        open_tray_layer(kids, level + 1, item.id, prefer_x, prefer_y, parent_left, true);
    });
}

void DeskUi::open_tray_menu(const TrayIcon& icon) {
    close_icon_tip();
    close_tray_from(0);
    m_tray_popup_icon = icon;
    auto items        = m_tray.menu_items(icon);
    if (items.empty()) {
        int x = 0;
        int y = 0;
        read_pointer(x, y);
        m_tray.context(icon, x, y);
        return;
    }
    int x = 8;
    int y = 8;
    read_pointer(x, y);
    open_tray_layer(items, 0, -1, x, y, 0, false);
}

void DeskUi::open_tray_layer(const std::vector<TrayMenuItem>& items, size_t level, int item_id, int prefer_x, int prefer_y, int parent_left, bool beside) {
    const int   row_h  = 28;
    const int   width  = 240;
    const int   height = tray_popup_height(items);
    std::string monitors_json;
    run_capture({hyprctl_bin(), "monitors", "-j"}, monitors_json);
    const auto monitors = parse_monitors(monitors_json);
    const auto place    = place_popup(prefer_x, prefer_y, width, height, parent_left, beside, monitors, named_monitor(monitors, m_place.monitor_name));

    auto background = CRectangleBuilder::begin()
                          ->color([this] { return m_palette->m_colors.background; })
                          ->borderColor([this] { return m_palette->m_colors.alternateBase; })
                          ->borderThickness(1)
                          ->rounding(m_palette->m_vars.smallRounding)
                          ->size(percent_box(1, 1))
                          ->commence();
    background->setReceivesMouse(true);
    background->setMouseLeave([this]() { queue_dismiss_tray_tree(); });
    auto column = CColumnLayoutBuilder::begin()->gap(2)->size(fill_auto())->commence();
    column->setMargin(6);
    if (items.empty())
        column->addChild(CTextBuilder::begin()->text("No menu items")->size(bar_size(1, static_cast<float>(row_h)))->commence());
    int row_y = place.global_y + 6;
    for (const auto& item : items) {
        if (item.separator) {
            column->addChild(CRectangleBuilder::begin()->color([this] { return m_palette->m_colors.alternateBase; })->size(bar_size(1, 1))->commence());
            row_y += 3;
            continue;
        }
        const int   row_top = row_y;
        row_y += row_h + 2;
        std::string label = item.label.empty() ? std::string{"Item"} : item.label;
        if (item.submenu)
            label += "  ›";
        auto button = CButtonBuilder::begin()
                          ->label(std::move(label))
                          ->ellipsize(true)
                          ->noBorder(true)
                          ->enabled(item.enabled)
                          ->size(bar_size(1, static_cast<float>(row_h)))
                          ->onMainClick([this, item, level, row_top, parent_gx = place.global_x, parent_w = width](CSharedPointer<CButtonElement>) {
                              if (item.submenu) {
                                  queue_tray_hover(item, level, parent_gx + parent_w + 6, row_top, parent_gx, true);
                                  return;
                              }
                              if (!item.enabled)
                                  return;
                              m_tray.activate_menu_item(m_tray_popup_icon, item.id);
                              m_backend->addIdle([this] { close_menu(); });
                          })
                          ->commence();
        button->setReceivesMouse(true);
        button->setMouseLeave([this]() { queue_dismiss_tray_tree(); });
        if (item.submenu)
            button->setMouseEnter([this, item, level, row_top, parent_gx = place.global_x, parent_w = width](const Vector2D&) {
                queue_tray_hover(item, level, parent_gx + parent_w + 6, row_top, parent_gx, true);
            });
        else
            button->setMouseEnter([this, level](const Vector2D&) { queue_tray_hover(TrayMenuItem{}, level, 0, 0, 0, false); });
        column->addChild(button);
    }
    background->addChild(column);
    TrayLayer layer;
    layer.gx      = place.global_x;
    layer.gy      = place.global_y;
    layer.width   = width;
    layer.height  = height;
    layer.item_id = item_id;
    auto window   = CWindowBuilder::begin()
                      ->type(HT_WINDOW_LAYER)
                      ->appClass("hyprdesk-menu")
                      ->appTitle("Tray menu")
                      ->preferredSize({static_cast<double>(width), static_cast<double>(height)})
                      ->anchor(kAnchorTopLeft)
                      ->marginTopLeft({static_cast<double>(place.local_x), static_cast<double>(place.local_y)})
                      ->exclusiveZone(-1)
                      ->layer(3)
                      ->kbInteractive(0);
    bind_output(window, m_backend.get(), m_place.monitor_name);
    layer.window = window->commence();
    layer.window->m_rootElement->addChild(background);
    layer.window->open();
    if (m_tray_layers.size() > level) {
        if (m_tray_layers[level].window)
            m_tray_layers[level].window->close();
        m_tray_layers[level] = std::move(layer);
        close_tray_from(level + 1);
    } else {
        m_tray_layers.push_back(std::move(layer));
    }
}

void DeskUi::tick_clock() {
    if (!m_menu_open)
        return;
    m_stats = cached_stats();
    if (m_clock)
        m_clock->setText(m_stats.clock);
    if (m_date)
        m_date->setText(m_stats.date);
    if (m_cpu_text)
        m_cpu_text->setText(m_stats.cpu);
    if (m_mem_text)
        m_mem_text->setText(m_stats.mem);
    if (m_gpu_text)
        m_gpu_text->setText(m_stats.gpu);
    if (m_net_text)
        m_net_text->setText(m_stats.net);
    m_backend->addTimer(std::chrono::seconds(1), [this](CAtomicSharedPointer<CTimer>, void*) { tick_clock(); }, nullptr);
}

void DeskUi::run() {
    m_backend->enterLoop();
    m_stop.store(true);
    if (m_stats_thread.joinable())
        m_stats_thread.join();
    if (m_volume_thread.joinable())
        m_volume_thread.join();
}

} // namespace

int run_daemon(bool open_menu) {
    const int listen_fd = acquire_server_socket();
    if (listen_fd < 0)
        return 0;
    DeskUi ui(open_menu, listen_fd);
    ui.run();
    return 0;
}
