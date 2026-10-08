#pragma once

#include "logic.hpp"

#include <string>
#include <vector>

struct TrayIcon {
    std::string service;
    std::string path;
    std::string id;
    std::string title;
    std::string icon;
    bool        item_is_menu = false;
};

class StatusTray {
  public:
    StatusTray() = default;
    ~StatusTray();

    StatusTray(const StatusTray&)            = delete;
    StatusTray& operator=(const StatusTray&) = delete;

    bool                      start();
    void                      process();
    int                       fd() const;
    const std::vector<TrayIcon>& items() const;
    void                      refresh();
    void                      activate(const TrayIcon& icon, int x, int y);
    void                      secondary(const TrayIcon& icon, int x, int y);
    void                      context(const TrayIcon& icon, int x, int y);
    void                      scroll(const TrayIcon& icon, int delta, const char* orientation);
    void                      register_item(const std::string& argument, const std::string& sender);
    void                      drop_service(const std::string& service);

  private:
    struct Bus;
    Bus*                    m_bus = nullptr;
    std::vector<TrayIcon>   m_items;

    void read_item(TrayIcon& icon);
    void call_item(const TrayIcon& icon, const char* method, const char* types, int a, int b, const char* text);
};
