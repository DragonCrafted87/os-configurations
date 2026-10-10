#pragma once

#include "logic.hpp"

#include <cstdint>
#include <string>
#include <vector>

struct TrayMenuItem {
    int                        id        = 0;
    std::string                label;
    bool                       separator = false;
    bool                       enabled   = true;
    bool                       submenu   = false;
    std::vector<TrayMenuItem>  children;
};

struct TrayIcon {
    std::string service;
    std::string unique;
    std::string path;
    std::string id;
    std::string title;
    std::string icon;
    std::string icon_theme;
    std::vector<uint8_t> icon_png;
    std::string menu_path;
    bool        item_is_menu = false;
};

// Network-order ARGB (A, R, G, B) to a PNG. Empty when the size is unusable.
std::vector<uint8_t> argb_to_png(int width, int height, const uint8_t* pixels, size_t size);
int                  tray_popup_height(const std::vector<TrayMenuItem>& items);

class StatusTray {
  public:
    StatusTray() = default;
    ~StatusTray();

    StatusTray(const StatusTray&)            = delete;
    StatusTray& operator=(const StatusTray&) = delete;

    bool                      start();
    void                      process();
    void                      announce();
    int                       fd() const;
    uint64_t                  generation() const;
    const std::vector<TrayIcon>& items() const;
    void                      refresh();
    void                      reload_icon(const std::string& service, const std::string& path);
    void                      activate(const TrayIcon& icon, int x, int y);
    void                      secondary(const TrayIcon& icon, int x, int y);
    void                      context(const TrayIcon& icon, int x, int y);
    void                      scroll(const TrayIcon& icon, int delta, const char* orientation);
    std::vector<TrayMenuItem> menu_items(const TrayIcon& icon);
    std::vector<TrayMenuItem> submenu_items(const TrayIcon& icon, int id);
    void                      activate_menu_item(const TrayIcon& icon, int id);
    void                      register_item(const std::string& argument, const std::string& sender);
    void                      drop_service(const std::string& service);

  private:
    struct Bus;
    Bus*                    m_bus = nullptr;
    std::vector<TrayIcon>   m_items;
    uint64_t                m_generation = 0;

    void read_item(TrayIcon& icon);
    void call_item(const TrayIcon& icon, const char* method, const char* types, int a, int b, const char* text);
};
