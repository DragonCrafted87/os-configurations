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

CHyprColor over_red() {
    return {0xEF / 255.F, 0x29 / 255.F, 0x29 / 255.F, 1.F};
}

class DeskUi {
  public:
    explicit DeskUi(bool open_menu);
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
    void close_client(const Client& client);
    void power(const std::string& action);
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
    CSharedPointer<CColumnLayoutElement>  m_menu_layout;
    CSharedPointer<CTextboxElement>       m_search_box;
    CSharedPointer<CTextElement>          m_clock;
    CSharedPointer<CTextElement>          m_date;
    CSharedPointer<CTextElement>          m_stats_text;
    CSharedPointer<CTextElement>          m_osd_label;
    CAtomicSharedPointer<CTimer>          m_osd_timer;
    std::atomic<bool>                     m_stop{false};
    std::thread                           m_volume_thread;
};

DeskUi::DeskUi(bool open_menu) : m_backend(IBackend::create()), m_palette(m_backend->getPalette()) {
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
    m_listen = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (m_listen >= 0) {
        const auto path = desk_socket_path();
        unlink(path.c_str());
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        std::snprintf(address.sun_path, sizeof(address.sun_path), "%s", path.c_str());
        if (bind(m_listen, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0 && listen(m_listen, 8) == 0) {
            m_backend->addFd(m_listen, [this] {
                while (true) {
                    const int client = accept4(m_listen, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (client < 0)
                        break;
                    char    buffer[64] = {};
                    const auto got = read(client, buffer, sizeof(buffer) - 1);
                    close(client);
                    if (got > 0)
                        handle_command(parse_command(buffer));
                }
            });
        }
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
    if (m_osd)
        m_osd->close();
    auto background = CRectangleBuilder::begin()
                          ->color([this] { return m_palette->m_colors.background; })
                          ->borderColor([this] { return volume_overdrive(m_volume) ? over_red() : m_palette->m_colors.alternateBase; })
                          ->borderThickness(1)
                          ->rounding(m_palette->m_vars.bigRounding)
                          ->size(percent_box(1, 1))
                          ->commence();
    auto column = CColumnLayoutBuilder::begin()->gap(6)->size(percent_box(1, 1))->commence();
    column->setMargin(8);
    m_osd_label = CTextBuilder::begin()
                      ->text(osd_label(m_volume))
                      ->align(HT_FONT_ALIGN_CENTER)
                      ->fontSize({CFontSize::HT_FONT_SMALL, 1.F})
                      ->color([this] { return volume_overdrive(m_volume) ? over_red() : m_palette->m_colors.text; })
                      ->size(bar_size(1, 16))
                      ->commence();
    auto track = CRectangleBuilder::begin()->color([this] { return m_palette->m_colors.base; })->rounding(8)->size(percent_box(1, 1))->commence();
    track->setGrow(true);
    const float fill = static_cast<float>(volume_fill(m_volume));
    if (fill > 0.F) {
        auto bar = CRectangleBuilder::begin()
                       ->color([this] { return volume_overdrive(m_volume) ? over_red() : m_palette->m_colors.accent; })
                       ->rounding(8)
                       ->size(percent_box(1, fill))
                       ->commence();
        bar->setPositionMode(IElement::HT_POSITION_ABSOLUTE);
        bar->setPositionFlag(IElement::HT_POSITION_FLAG_BOTTOM, true);
        track->addChild(bar);
    }
    column->addChild(m_osd_label);
    column->addChild(track);
    background->addChild(column);
    m_osd = CWindowBuilder::begin()
                ->type(HT_WINDOW_LAYER)
                ->appClass("hyprdesk-osd")
                ->appTitle("Volume")
                ->preferredSize({44, 220})
                ->anchor(kAnchorTopLeft)
                ->marginTopLeft({24, 24})
                ->exclusiveZone(-1)
                ->layer(3)
                ->kbInteractive(0)
                ->commence();
    m_osd->m_rootElement->addChild(background);
    m_osd->open();
    if (m_osd_timer)
        m_osd_timer->cancel();
    m_osd_timer = m_backend->addTimer(std::chrono::milliseconds(1800), [this](CAtomicSharedPointer<CTimer>, void*) { hide_osd(); }, nullptr);
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
    const std::string script = "hyprctl --batch \"dispatch movetoworkspace " + std::to_string(m_place.workspace) + ",address:" + client.address +
                               "; dispatch focuswindow address:" + client.address + "; dispatch togglespecialworkspace minimized\"";
    run_detached({"sh", "-c", script});
    m_backend->addIdle([this] { close_menu(); });
}

void DeskUi::close_client(const Client& client) {
    if (!safe_window_address(client.address))
        return;
    run_detached({"hyprctl", "dispatch", "closewindow", "address:" + client.address});
    m_backend->addIdle([this] { rebuild_menu(); });
}

void DeskUi::launch(const DesktopEntry& entry) {
    std::string clients_json;
    run_capture({"hyprctl", "clients", "-j"}, clients_json);
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
            run_detached({"hyprctl", "dispatch", "movetoworkspace", std::to_string(m_place.workspace) + ",address:" + client.address});
            run_detached({"hyprctl", "dispatch", "focuswindow", "address:" + client.address});
            m_backend->addIdle([this] { close_menu(); });
            return;
        }
    }
    auto args = split_exec(entry.exec);
    if (args.empty())
        return;
    std::string command;
    for (const auto& arg : args) {
        if (!command.empty())
            command.push_back(' ');
        command += arg;
    }
    run_detached({"hyprctl", "dispatch", "workspace", std::to_string(m_place.workspace)});
    run_detached({"hyprctl", "dispatch", "exec", command});
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
    auto list = CColumnLayoutBuilder::begin()->gap(2)->size(bar_size(1, 1))->commence();
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
    const int height = std::max(80, m_place.monitor_h - m_place.menu_top - 8);
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
    m_menu_layout->addChild(m_search_box);

    const struct {
        const char* label;
        const char* cat;
    } categories[] = {
        {"All", "*"},       {"Accessories", "Utility"}, {"Development", "Development"}, {"Games", "Game"},     {"Graphics", "Graphics"},
        {"Internet", "Network"}, {"Multimedia", "AudioVideo"}, {"Office", "Office"}, {"Settings", "Settings"}, {"System", "System"},
    };
    for (const auto& category : categories) {
        const bool selected = !m_search.empty() ? false : m_category == category.cat;
        auto button = CButtonBuilder::begin()
                          ->label(std::string{category.label})
                          ->accent(selected)
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
        button->setMouseEnter([this, category](const Vector2D&) {
            if (m_pinned || !m_search.empty())
                return;
            m_category       = category.cat;
            m_category_label = category.label;
            rebuild_flyout();
        });
        m_menu_layout->addChild(button);
    }

    auto header = CRowLayoutBuilder::begin()->gap(8)->size(bar_size(1, 22))->commence();
    header->addChild(CTextBuilder::begin()
                         ->text(m_minimized ? std::string{"Minimized"} : std::string{"Windows"})
                         ->fontSize({CFontSize::HT_FONT_SMALL, 1.F})
                         ->size(bar_size(1, 22))
                         ->commence());
    header->addChild(CButtonBuilder::begin()
                         ->label(m_minimized ? std::string{"All"} : std::string{"Min"})
                         ->noBorder(true)
                         ->size(box_size(48, 22))
                         ->onMainClick([this](CSharedPointer<CButtonElement>) {
                             m_minimized = !m_minimized;
                             m_backend->addIdle([this] { rebuild_menu(); });
                         })
                         ->commence());
    header->addChild(CButtonBuilder::begin()
                         ->label("Refresh")
                         ->noBorder(true)
                         ->size(box_size(72, 22))
                         ->onMainClick([this](CSharedPointer<CButtonElement>) {
                             std::string json;
                             run_capture({"hyprctl", "clients", "-j"}, json);
                             m_clients = parse_clients(json);
                             m_backend->addIdle([this] { rebuild_menu(); });
                         })
                         ->commence());
    m_menu_layout->addChild(header);

    auto window_scroll = CScrollAreaBuilder::begin()->scrollY(true)->size(bar_size(1, windows.empty() ? 28.F : std::min<float>(static_cast<float>(windows.size()), 8.F) * 34.F))->commence();
    auto window_list   = CColumnLayoutBuilder::begin()->gap(2)->size(bar_size(1, 1))->commence();
    if (windows.empty()) {
        window_list->addChild(CTextBuilder::begin()->text(m_minimized ? std::string{"No minimized windows"} : std::string{"No windows"})->size(bar_size(1, 24))->commence());
    }
    for (const auto& client : windows) {
        const auto title = client.title.empty() ? std::string{"(no title)"} : client.title;
        auto button = CButtonBuilder::begin()
                          ->label(std::string{title})
                          ->ellipsize(true)
                          ->noBorder(true)
                          ->size(bar_size(1, 32))
                          ->onMainClick([this, client](CSharedPointer<CButtonElement>) { restore_client(client); })
                          ->onRightClick([this, client](CSharedPointer<CButtonElement>) { close_client(client); })
                          ->commence();
        window_list->addChild(button);
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
                              ->onMainClick([this, icon](CSharedPointer<CButtonElement>) { m_tray.activate(icon, 0, 0); })
                              ->onRightClick([this, icon](CSharedPointer<CButtonElement>) { m_tray.context(icon, 0, 0); })
                              ->commence();
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
        m_menu_layout->addChild(tray_row);
    }

    auto volume_row = CRowLayoutBuilder::begin()->gap(8)->size(bar_size(1, 28))->commence();
    volume_row->addChild(CButtonBuilder::begin()
                             ->label(menu_volume_caption(m_volume))
                             ->noBorder(true)
                             ->size(box_size(56, 28))
                             ->onMainClick([this](CSharedPointer<CButtonElement>) { toggle_mute(); })
                             ->commence());
    auto slider = CSliderBuilder::begin()
                      ->min(0)
                      ->max(1.5F)
                      ->val(static_cast<float>(m_volume.muted ? 0 : m_volume.level))
                      ->size(bar_size(1, 20))
                      ->onChanged([this](CSharedPointer<CSliderElement>, float value) {
                          const double snapped = snap_volume(value);
                          if (std::abs(snapped - m_volume.level) < 0.001 && !m_volume.muted)
                              return;
                          apply_volume(snapped, true);
                      })
                      ->commence();
    slider->setMouseAxis([this](Input::eAxisAxis axis, float delta) {
        if (axis != Input::AXIS_AXIS_VERTICAL || delta == 0.F)
            return;
        const double dir = delta > 0 ? 1 : -1;
        apply_volume(snap_volume(m_volume.level + (dir * 0.025)), true);
        if (m_menu_open)
            m_backend->addIdle([this] { rebuild_menu(); });
    });
    volume_row->addChild(slider);
    volume_row->addChild(CTextBuilder::begin()
                             ->text(menu_volume_percent(m_volume))
                             ->align(HT_FONT_ALIGN_RIGHT)
                             ->color([this] { return volume_overdrive(m_volume) ? over_red() : m_palette->m_colors.text; })
                             ->size(box_size(56, 28))
                             ->commence());
    m_menu_layout->addChild(volume_row);

    m_stats = read_stats(m_cpu);
    m_cpu   = read_cpu_sample();
    m_stats_text = CTextBuilder::begin()->text(m_stats.cpu + "  " + m_stats.mem + "  " + m_stats.gpu + "  " + m_stats.net)->size(bar_size(1, 22))->commence();
    m_clock = CTextBuilder::begin()->text(std::string{m_stats.clock})->fontSize({CFontSize::HT_FONT_H1, 1.F})->color([this] { return m_palette->m_colors.accent; })->size(bar_size(1, 24))->commence();
    m_date = CTextBuilder::begin()->text(std::string{m_stats.date})->fontSize({CFontSize::HT_FONT_H2, 1.F})->color([this] { return m_palette->m_colors.accent; })->size(bar_size(1, 22))->commence();
    m_menu_layout->addChild(m_stats_text);
    m_menu_layout->addChild(m_clock);
    m_menu_layout->addChild(m_date);

    auto power_row = CRowLayoutBuilder::begin()->gap(4)->size(bar_size(1, 36))->commence();
    for (const auto& action : {"lock", "logout", "suspend", "reboot", "shutdown"}) {
        auto button = CButtonBuilder::begin()
                          ->label(std::string{action})
                          ->noBorder(action != std::string{"shutdown"})
                          ->accent(action == std::string{"shutdown"})
                          ->size(bar_size(1, 32))
                          ->onMainClick([this, action](CSharedPointer<CButtonElement>) { power(action); })
                          ->commence();
        power_row->addChild(button);
    }
    m_menu_layout->addChild(power_row);
    if (m_search_box)
        m_search_box->focus();
}

void DeskUi::open_menu_at_cursor() {
    std::string cursor;
    std::string monitors_json;
    std::string clients_json;
    run_capture({"hyprctl", "cursorpos"}, cursor);
    run_capture({"hyprctl", "monitors", "-j"}, monitors_json);
    run_capture({"hyprctl", "clients", "-j"}, clients_json);
    int x = 8;
    int y = 8;
    if (!cursor.empty())
        parse_cursor_pos(cursor, x, y);
    const int estimate = 36 + (10 * 32) + 24 + (4 * 34) + 28 + 28 + 22 + 24 + 22 + 40 + 48;
    m_place            = place_menu(x, y, parse_monitors(monitors_json), estimate);
    m_clients          = parse_clients(clients_json);
    m_apps             = load_desktop_entries();
    m_menu_open        = true;
    m_search.clear();
    m_category.clear();
    m_pinned = false;

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
    m_menu->open();
    tick_clock();
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
    DeskUi ui(open_menu);
    ui.run();
    return 0;
}
