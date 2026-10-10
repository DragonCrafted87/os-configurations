#include "ui.hpp"

#include "logic.hpp"
#include "tray.hpp"

#include <hyprtoolkit/core/Backend.hpp>
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

std::string wide_status_line(const StatsText& stats) {
    std::string mem = stats.mem.empty() ? "mem 000/000.0G" : stats.mem;
    const auto  slash = mem.find('/');
    if (slash != std::string::npos) {
        const auto whole  = mem.substr(slash + 1);
        const auto dot    = whole.find('.');
        const auto digits = std::max<size_t>(1, dot == std::string::npos ? whole.size() : dot);
        mem               = "mem " + std::string(digits, '8') + "/" + whole;
    }
    const std::string gpu = stats.gpu.find('%') == std::string::npos ? "gpu 100% 100°" : stats.gpu;
    return "cpu 100%  " + mem + "  " + gpu + "  " + stats.net;
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
    const std::string code = "hl.dsp.window.move({ workspace = " + ws + ", follow = false, window = " + window + " })()\n" +
                             "hl.dsp.focus({ window = " + window + " })()\n";
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
    void show_tray_menu(const std::vector<TrayMenuItem>& items);
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
    CSharedPointer<IWindow>               m_tray_popup;
    TrayIcon                              m_tray_popup_icon;
    std::vector<std::vector<TrayMenuItem>> m_tray_menu_stack;
    CSharedPointer<CColumnLayoutElement>  m_menu_layout;
    CSharedPointer<CTextboxElement>       m_search_box;
    CSharedPointer<CTextElement>          m_clock;
    CSharedPointer<CTextElement>          m_date;
    CSharedPointer<CTextElement>          m_stats_text;
    CSharedPointer<CTextElement>          m_volume_readout;
    CSharedPointer<CSliderElement>        m_menu_slider;
    CSharedPointer<CTextElement>          m_osd_label;
    CSharedPointer<CRectangleElement>     m_osd_track;
    CAtomicSharedPointer<CTimer>          m_osd_timer;
    std::atomic<bool>                     m_stop{false};
    std::thread                           m_volume_thread;
};

DeskUi::DeskUi(bool open_menu, int listen_fd) : m_backend(IBackend::create()), m_palette(m_backend->getPalette()), m_listen(listen_fd) {
    int pipes[2] = {-1, -1};
    if (pipe2(pipes, O_CLOEXEC | O_NONBLOCK) == 0)
        m_poke = pipes[0];
    m_volume = read_volume();
    m_apps   = load_desktop_entries();
    if (m_tray.start() && m_tray.fd() >= 0) {
        m_backend->addFd(m_tray.fd(), [this] { m_tray.process(); });
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
        m_backend->addIdle([this] { rebuild_menu(); });
    show_osd();
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
        m_backend->addIdle([this] { rebuild_menu(); });
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

    // One layer for the life of the process. Replacing it on each step
    // leaves the previous surface up until the compositor destroys it.
    if (!m_osd) {
        float widest = track_w;
        for (const char* sample : {"112.5%", "147.5%", "72.5%", "150%", "MUTE"})
            widest = std::max(widest, measure_label(sample, family, pt).width);
        // 72 is about three quarters of the old 96px panel. Grow if a
        // label would touch the pad.
        const float osd_w = std::max(72.F, widest + (panel_pad * 2.F));
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
        m_osd = CWindowBuilder::begin()
                    ->type(HT_WINDOW_LAYER)
                    ->appClass("hyprdesk-osd")
                    ->appTitle("Volume")
                    ->preferredSize({osd_w, osd_h})
                    ->anchor(kAnchorTopLeft)
                    ->marginTopLeft({24, 24})
                    ->exclusiveZone(-1)
                    ->layer(3)
                    ->kbInteractive(0)
                    ->commence();
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
    m_menu_open = false;
    m_pinned    = false;
    m_category.clear();
    if (m_menu)
        m_menu->close();
    if (m_flyout)
        m_flyout->close();
    if (m_dismiss)
        m_dismiss->close();
    if (m_tray_popup)
        m_tray_popup->close();
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
    const std::string code = "hl.dsp.focus({ workspace = " + ws + " })()\n" +
                             "hl.dsp.exec_cmd(" + lua_quote(command) + ", { workspace = " + ws + " })()\n";
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
                          ->label(std::string{app.name})
                          ->ellipsize(true)
                          ->noBorder(true)
                          ->fontSize({CFontSize::HT_FONT_TEXT, 1.F})
                          ->size(bar_size(1, 34))
                          ->onMainClick([this, app](CSharedPointer<CButtonElement>) { launch(app); })
                          ->onRightClick([this, app](CSharedPointer<CButtonElement>) {
                              run_detached({"code", "--", app.path});
                              m_backend->addIdle([this] { close_menu(); });
                          })
                          ->commence();
        list->addChild(button);
    }
    scroll->addChild(list);
    column->addChild(scroll);
    background->addChild(column);
    const int count   = apps.empty() ? 1 : static_cast<int>(std::min(apps.size(), static_cast<size_t>(400)));
    const int natural = 16 + 8 + 4 + count * 36 + 16;
    const int height  = std::min(std::max(80, m_place.menu_h), std::max(80, natural));
    m_flyout         = CWindowBuilder::begin()
                   ->type(HT_WINDOW_LAYER)
                   ->appClass("hyprdesk-flyout")
                   ->appTitle("Apps")
                   ->preferredSize({static_cast<double>(m_place.flyout_w), static_cast<double>(height)})
                   ->anchor(kAnchorTopLeft)
                   ->marginTopLeft({static_cast<double>(m_place.flyout_left), static_cast<double>(m_place.menu_top)})
                   ->exclusiveZone(-1)
                   ->layer(3)
                   ->kbInteractive(0)
                   ->commence();
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
    m_menu_layout->clearChildren();
    m_menu_slider.reset();
    m_volume_readout.reset();
    auto upper = CColumnLayoutBuilder::begin()->gap(6)->size(fill_auto())->commence();
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
    auto below_categories = [this](const Vector2D&) { leave_categories(); };
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
                       ->size(bar_size(1, 32))
                       ->commence();
    upper->addChild(m_search_box);

    const struct {
        const char* label;
        const char* cat;
    } categories[] = {
        {"All", "*"},       {"Accessories", "Utility"}, {"Development", "Development"}, {"Games", "Game"},     {"Graphics", "Graphics"},
        {"Internet", "Network"}, {"Multimedia", "AudioVideo"}, {"Office", "Office"}, {"Settings", "Settings"}, {"System", "System"},
    };
    for (const auto& category : categories) {
        auto button = CButtonBuilder::begin()
                          ->label(std::string{category.label})
                          ->noBorder(true)
                          ->fontSize({CFontSize::HT_FONT_TEXT, 1.F})
                          ->size(bar_size(1, 30))
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

    auto scroller = CScrollAreaBuilder::begin()->scrollY(true)->size(bar_size(1, 1))->commence();
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

    const float window_h = windows.empty() ? 28.F : std::min<float>(static_cast<float>(windows.size()), 6.F) * 44.F;
    auto window_scroll = CScrollAreaBuilder::begin()->scrollY(true)->size(bar_size(1, window_h))->commence();
    window_scroll->setReceivesMouse(true);
    window_scroll->setMouseEnter(below_categories);
    auto window_list   = CColumnLayoutBuilder::begin()->gap(2)->size(fill_auto())->commence();
    if (windows.empty()) {
        window_list->addChild(CTextBuilder::begin()->text(m_minimized ? std::string{"No minimized windows"} : std::string{"No windows"})->async(false)->size(bar_size(1, 24))->commence());
    }
    for (const auto& client : windows) {
        const auto title = client.title.empty() ? std::string{"(no title)"} : client.title;
        const auto meta  = window_meta(client);
        auto row = CRectangleBuilder::begin()->color([] { return CHyprColor{0, 0, 0, 0}; })->rounding(m_palette->m_vars.smallRounding)->size(bar_size(1, 42))->commence();
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
    if (!m_tray.items().empty()) {
        auto tray_row = CRowLayoutBuilder::begin()->gap(4)->size(bar_size(1, 28))->commence();
        for (const auto& icon : m_tray.items()) {
            const auto label = !icon.title.empty() ? icon.title : (!icon.id.empty() ? icon.id : icon.service);
            auto button = CButtonBuilder::begin()
                              ->label(std::string{label})
                              ->ellipsize(true)
                              ->noBorder(true)
                              ->size(box_size(28, 28))
                              ->onMainClick([this, icon](CSharedPointer<CButtonElement>) {
                                  leave_categories();
                                  m_tray.activate(icon, 0, 0);
                              })
                              ->onRightClick([this, icon](CSharedPointer<CButtonElement>) {
                                  leave_categories();
                                  m_backend->addIdle([this, icon] { open_tray_menu(icon); });
                              })
                              ->commence();
            button->setReceivesMouse(true);
            button->setMouseEnter(below_categories);
            button->setMouseButton([this, icon](Input::eMouseButton button, bool down) {
                if (!down || button != Input::MOUSE_BUTTON_MIDDLE)
                    return;
                m_tray.secondary(icon, 0, 0);
            });
            button->setMouseAxis([this, icon](Input::eAxisAxis axis, float delta) {
                if (axis != Input::AXIS_AXIS_VERTICAL || delta == 0.F)
                    return;
                m_tray.scroll(icon, delta > 0 ? 1 : -1, "vertical");
            });
            if (!icon.icon.empty()) {
                if (auto picture = m_backend->systemIcons()->lookupIcon(icon.icon); picture && picture->exists()) {
                    auto image = CImageBuilder::begin()->icon(picture)->size(box_size(20, 20))->commence();
                    button->addChild(image);
                }
            }
            button->setTooltip(std::string{label});
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
    volume_row->addChild(mute_button);
    auto slider = CSliderBuilder::begin()
                      ->min(0)
                      ->max(1.5F)
                      ->val(static_cast<float>(m_volume.muted ? 0 : m_volume.level))
                      ->size(box_size(80, 28))
                      ->onChanged([this](CSharedPointer<CSliderElement>, float value) {
                          const double snapped = snap_volume(value);
                          if (std::abs(snapped - m_volume.level) < 0.001 && !m_volume.muted)
                              return;
                          apply_volume(snapped, true);
                          if (m_volume_readout)
                              m_volume_readout->setText(menu_volume_percent(m_volume));
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
        if (m_menu_slider)
            m_menu_slider->rebuild()->val(static_cast<float>(m_volume.muted ? 0.0 : m_volume.level))->commence();
        if (m_volume_readout)
            m_volume_readout->setText(menu_volume_percent(m_volume));
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

    m_stats = read_stats(m_cpu);
    m_cpu   = read_cpu_sample();
    const std::string status = m_stats.cpu + "  " + m_stats.mem + "  " + m_stats.gpu + "  " + m_stats.net;
    const float status_w = std::max(1.F, measure_label(wide_status_line(m_stats), m_palette->m_vars.fontFamily, static_cast<float>(m_palette->m_vars.fontSize)).width);
    m_menu_layout->addChild(rule());
    m_stats_text = CTextBuilder::begin()->text(std::string{status})->async(false)->size(box_size(status_w, 22))->commence();
    m_stats_text->setReceivesMouse(true);
    m_stats_text->setMouseEnter(below_categories);
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
    m_menu_layout->addChild(m_stats_text);
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
    const int estimate = 20 + 36 + (10 * 30) + (9 * 6) + 22 + (6 * 34) + 28 + 32 + 22 + 36 + 32 + 40 + (14 * 6);
    m_place            = place_menu(x, y, parse_monitors(monitors_json), estimate);
    m_stats            = read_stats(m_cpu);
    m_cpu              = read_cpu_sample();
    const float status_w = measure_label(wide_status_line(m_stats), m_palette->m_vars.fontFamily, static_cast<float>(m_palette->m_vars.fontSize)).width + 28.F;
    if (status_w > static_cast<float>(m_place.menu_w))
        m_place.menu_w = std::min(m_place.monitor_w - 16, static_cast<int>(std::ceil(status_w)));
    m_place.flyout_on_left = (m_place.menu_left + m_place.menu_w + m_place.flyout_gap + m_place.flyout_w) > (m_place.monitor_w - 8);
    if (m_place.flyout_on_left)
        m_place.flyout_left = std::max(8, m_place.menu_left - m_place.flyout_w - m_place.flyout_gap);
    else
        m_place.flyout_left = m_place.menu_left + m_place.menu_w + m_place.flyout_gap;
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
    m_dismiss = CWindowBuilder::begin()
                    ->type(HT_WINDOW_LAYER)
                    ->appClass("hyprdesk-dismiss")
                    ->preferredSize({static_cast<double>(m_place.monitor_w), static_cast<double>(m_place.monitor_h)})
                    ->anchor(kAnchorAll)
                    ->exclusiveZone(-1)
                    ->layer(2)
                    ->kbInteractive(0)
                    ->commence();
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
    m_menu = CWindowBuilder::begin()
                 ->type(HT_WINDOW_LAYER)
                 ->appClass("hyprdesk")
                 ->appTitle("Desk")
                 ->preferredSize({static_cast<double>(m_place.menu_w), static_cast<double>(m_place.menu_h)})
                 ->anchor(kAnchorTopLeft)
                 ->marginTopLeft({static_cast<double>(m_place.menu_left), static_cast<double>(m_place.menu_top)})
                 ->exclusiveZone(-1)
                 ->layer(3)
                 ->kbInteractive(2)
                 ->commence();
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

void DeskUi::open_tray_menu(const TrayIcon& icon) {
    m_tray_menu_stack.clear();
    m_tray_popup_icon = icon;
    auto items        = m_tray.menu_items(icon);
    if (items.empty()) {
        std::string cursor;
        run_capture({hyprctl_bin(), "cursorpos"}, cursor);
        int x = 0;
        int y = 0;
        parse_cursor_pos(cursor, x, y);
        m_tray.context(icon, x, y);
        return;
    }
    show_tray_menu(items);
}

void DeskUi::show_tray_menu(const std::vector<TrayMenuItem>& items) {
    if (m_tray_popup)
        m_tray_popup->close();
    const int row_h  = 28;
    const int width  = 240;
    const int shown  = static_cast<int>(std::min<size_t>(items.size() + (m_tray_menu_stack.empty() ? 0 : 1), 14));
    const int height = 16 + std::max(1, shown) * row_h;
    std::string cursor;
    std::string monitors_json;
    run_capture({hyprctl_bin(), "cursorpos"}, cursor);
    run_capture({hyprctl_bin(), "monitors", "-j"}, monitors_json);
    int x = 8;
    int y = 8;
    parse_cursor_pos(cursor, x, y);
    const auto anchor = clamp_on_output(x, y, width, height, parse_monitors(monitors_json));

    auto background = CRectangleBuilder::begin()
                          ->color([this] { return m_palette->m_colors.background; })
                          ->borderColor([this] { return m_palette->m_colors.alternateBase; })
                          ->borderThickness(1)
                          ->rounding(m_palette->m_vars.smallRounding)
                          ->size(percent_box(1, 1))
                          ->commence();
    auto column = CColumnLayoutBuilder::begin()->gap(2)->size(fill_auto())->commence();
    column->setMargin(6);
    if (!m_tray_menu_stack.empty()) {
        column->addChild(CButtonBuilder::begin()
                             ->label("Back")
                             ->noBorder(true)
                             ->size(bar_size(1, static_cast<float>(row_h)))
                             ->onMainClick([this](CSharedPointer<CButtonElement>) {
                                 if (m_tray_menu_stack.empty())
                                     return;
                                 auto previous = m_tray_menu_stack.back();
                                 m_tray_menu_stack.pop_back();
                                 m_backend->addIdle([this, previous] { show_tray_menu(previous); });
                             })
                             ->commence());
    }
    if (items.empty())
        column->addChild(CTextBuilder::begin()->text("No menu items")->size(bar_size(1, static_cast<float>(row_h)))->commence());
    for (const auto& item : items) {
        if (item.separator) {
            column->addChild(CRectangleBuilder::begin()->color([this] { return m_palette->m_colors.alternateBase; })->size(bar_size(1, 1))->commence());
            continue;
        }
        std::string label = item.label.empty() ? std::string{"Item"} : item.label;
        if (item.submenu)
            label += "  ›";
        auto button = CButtonBuilder::begin()
                          ->label(std::move(label))
                          ->ellipsize(true)
                          ->noBorder(true)
                          ->enabled(item.enabled)
                          ->size(bar_size(1, static_cast<float>(row_h)))
                          ->onMainClick([this, item, items](CSharedPointer<CButtonElement>) {
                              if (item.submenu) {
                                  m_backend->addIdle([this, item, items] {
                                      auto kids = item.children.empty() ? m_tray.submenu_items(m_tray_popup_icon, item.id) : item.children;
                                      if (kids.empty())
                                          return;
                                      m_tray_menu_stack.push_back(items);
                                      show_tray_menu(kids);
                                  });
                                  return;
                              }
                              if (!item.enabled)
                                  return;
                              m_tray.activate_menu_item(m_tray_popup_icon, item.id);
                              m_backend->addIdle([this] { close_menu(); });
                          })
                          ->commence();
        if (item.submenu) {
            button->setReceivesMouse(true);
            button->setMouseEnter([this, item, items](const Vector2D&) {
                auto kids = item.children.empty() ? m_tray.submenu_items(m_tray_popup_icon, item.id) : item.children;
                if (kids.empty())
                    return;
                m_tray_menu_stack.push_back(items);
                show_tray_menu(kids);
            });
        }
        column->addChild(button);
    }
    background->addChild(column);
    m_tray_popup = CWindowBuilder::begin()
                       ->type(HT_WINDOW_LAYER)
                       ->appClass("hyprdesk-menu")
                       ->appTitle("Tray menu")
                       ->preferredSize({static_cast<double>(width), static_cast<double>(height)})
                       ->anchor(kAnchorTopLeft)
                       ->marginTopLeft({static_cast<double>(anchor.left), static_cast<double>(anchor.top)})
                       ->exclusiveZone(-1)
                       ->layer(3)
                       ->kbInteractive(0)
                       ->commence();
    m_tray_popup->m_rootElement->addChild(background);
    m_tray_popup->open();
}

void DeskUi::tick_clock() {
    if (!m_menu_open)
        return;
    m_stats = read_stats(m_cpu);
    m_cpu   = read_cpu_sample();
    if (m_clock)
        m_clock->setText(m_stats.clock);
    if (m_date)
        m_date->setText(m_stats.date);
    if (m_stats_text)
        m_stats_text->setText(m_stats.cpu + "  " + m_stats.mem + "  " + m_stats.gpu + "  " + m_stats.net);
    m_backend->addTimer(std::chrono::seconds(1), [this](CAtomicSharedPointer<CTimer>, void*) { tick_clock(); }, nullptr);
}

void DeskUi::run() {
    m_backend->enterLoop();
    m_stop.store(true);
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
