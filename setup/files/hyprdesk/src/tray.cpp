#include "tray.hpp"

#include <systemd/sd-bus.h>

#include <cstdio>
#include <cstring>

struct StatusTray::Bus {
    sd_bus*      bus          = nullptr;
    sd_bus_slot* slot         = nullptr;
    sd_bus_slot* name_slot    = nullptr;
    int          fd           = -1;
};

namespace {

int register_item(sd_bus_message* message, void* userdata, sd_bus_error*) {
    const char* argument = nullptr;
    int         read     = sd_bus_message_read(message, "s", &argument);
    if (read < 0)
        return read;
    auto* tray = static_cast<StatusTray*>(userdata);
    tray->register_item(argument ? argument : "", sd_bus_message_get_sender(message) ? sd_bus_message_get_sender(message) : "");
    return sd_bus_reply_method_return(message, "");
}

int register_host(sd_bus_message* message, void*, sd_bus_error*) {
    return sd_bus_reply_method_return(message, "");
}

int items_property(sd_bus*, const char*, const char*, const char*, sd_bus_message* reply, void* userdata, sd_bus_error*) {
    auto* tray   = static_cast<StatusTray*>(userdata);
    int   result = sd_bus_message_open_container(reply, SD_BUS_TYPE_ARRAY, "s");
    if (result < 0)
        return result;
    for (const auto& icon : tray->items()) {
        result = sd_bus_message_append(reply, "s", icon.service.c_str());
        if (result < 0)
            return result;
    }
    return sd_bus_message_close_container(reply);
}

int host_property(sd_bus*, const char*, const char*, const char*, sd_bus_message* reply, void*, sd_bus_error*) {
    int registered = 1;
    return sd_bus_message_append(reply, "b", registered);
}

int version_property(sd_bus*, const char*, const char*, const char*, sd_bus_message* reply, void*, sd_bus_error*) {
    int version = 0;
    return sd_bus_message_append(reply, "i", version);
}

int name_owner_changed(sd_bus_message* message, void* userdata, sd_bus_error*) {
    const char* name = nullptr;
    const char* old_owner = nullptr;
    const char* new_owner = nullptr;
    int         read = sd_bus_message_read(message, "sss", &name, &old_owner, &new_owner);
    if (read < 0)
        return 0;
    if (new_owner && *new_owner)
        return 0;
    if (name)
        static_cast<StatusTray*>(userdata)->drop_service(name);
    return 0;
}

const sd_bus_vtable kWatcher[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("RegisterStatusNotifierItem", "s", "", register_item, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("RegisterStatusNotifierHost", "s", "", register_host, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_PROPERTY("RegisteredStatusNotifierItems", "as", items_property, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("IsStatusNotifierHostRegistered", "b", host_property, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("ProtocolVersion", "i", version_property, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_SIGNAL("StatusNotifierItemRegistered", "s", 0),
    SD_BUS_SIGNAL("StatusNotifierItemUnregistered", "s", 0),
    SD_BUS_SIGNAL("StatusNotifierHostRegistered", "", 0),
    SD_BUS_VTABLE_END,
};

} // namespace

StatusTray::~StatusTray() {
    if (!m_bus)
        return;
    sd_bus_slot_unref(m_bus->name_slot);
    sd_bus_slot_unref(m_bus->slot);
    sd_bus_unref(m_bus->bus);
    delete m_bus;
}

bool StatusTray::start() {
    auto* bus = new Bus();
    if (sd_bus_open_user(&bus->bus) < 0) {
        delete bus;
        return false;
    }
    if (sd_bus_add_object_vtable(bus->bus, &bus->slot, "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", kWatcher, this) < 0) {
        sd_bus_unref(bus->bus);
        delete bus;
        return false;
    }
    if (sd_bus_request_name(bus->bus, "org.kde.StatusNotifierWatcher", 0) < 0) {
        sd_bus_slot_unref(bus->slot);
        sd_bus_unref(bus->bus);
        delete bus;
        return false;
    }
    sd_bus_match_signal(bus->bus, &bus->name_slot, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged",
                        name_owner_changed, this);
    bus->fd = sd_bus_get_fd(bus->bus);
    m_bus   = bus;
    sd_bus_emit_signal(bus->bus, "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "StatusNotifierHostRegistered", "");
    return true;
}

void StatusTray::process() {
    if (!m_bus)
        return;
    while (sd_bus_process(m_bus->bus, nullptr) > 0) {
    }
}

int StatusTray::fd() const {
    return m_bus ? m_bus->fd : -1;
}

const std::vector<TrayIcon>& StatusTray::items() const {
    return m_items;
}

void StatusTray::read_item(TrayIcon& icon) {
    if (!m_bus)
        return;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    char*        text  = nullptr;
    if (sd_bus_get_property_string(m_bus->bus, icon.service.c_str(), icon.path.c_str(), "org.kde.StatusNotifierItem", "Id", &error, &text) >= 0 && text) {
        icon.id = text;
        free(text);
        text = nullptr;
    }
    sd_bus_error_free(&error);
    error = SD_BUS_ERROR_NULL;
    if (sd_bus_get_property_string(m_bus->bus, icon.service.c_str(), icon.path.c_str(), "org.kde.StatusNotifierItem", "Title", &error, &text) >= 0 && text) {
        icon.title = text;
        free(text);
        text = nullptr;
    }
    sd_bus_error_free(&error);
    error = SD_BUS_ERROR_NULL;
    if (sd_bus_get_property_string(m_bus->bus, icon.service.c_str(), icon.path.c_str(), "org.kde.StatusNotifierItem", "IconName", &error, &text) >= 0 && text) {
        icon.icon = text;
        free(text);
    }
    sd_bus_error_free(&error);
    int menu = 0;
    error    = SD_BUS_ERROR_NULL;
    if (sd_bus_get_property_trivial(m_bus->bus, icon.service.c_str(), icon.path.c_str(), "org.kde.StatusNotifierItem", "ItemIsMenu", &error, 'b', &menu) >= 0)
        icon.item_is_menu = menu != 0;
    sd_bus_error_free(&error);
}

void StatusTray::register_item(const std::string& argument, const std::string& sender) {
    auto target = resolve_sni_target(argument, sender);
    if (target.service.empty() || target.path.empty())
        return;
    for (const auto& icon : m_items) {
        if (icon.service == target.service && icon.path == target.path)
            return;
    }
    TrayIcon icon;
    icon.service = target.service;
    icon.path    = target.path;
    read_item(icon);
    m_items.push_back(icon);
    if (m_bus)
        sd_bus_emit_signal(m_bus->bus, "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "StatusNotifierItemRegistered", "s", icon.service.c_str());
}

void StatusTray::drop_service(const std::string& service) {
    std::erase_if(m_items, [&](const TrayIcon& icon) { return icon.service == service; });
    if (m_bus)
        sd_bus_emit_signal(m_bus->bus, "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "StatusNotifierItemUnregistered", "s", service.c_str());
}

void StatusTray::refresh() {
    for (auto& icon : m_items)
        read_item(icon);
}

void StatusTray::call_item(const TrayIcon& icon, const char* method, const char* types, int a, int b, const char* text) {
    if (!m_bus)
        return;
    sd_bus_error    error = SD_BUS_ERROR_NULL;
    sd_bus_message* reply = nullptr;
    if (text)
        sd_bus_call_method(m_bus->bus, icon.service.c_str(), icon.path.c_str(), "org.kde.StatusNotifierItem", method, &error, &reply, types, a, text);
    else
        sd_bus_call_method(m_bus->bus, icon.service.c_str(), icon.path.c_str(), "org.kde.StatusNotifierItem", method, &error, &reply, types, a, b);
    sd_bus_error_free(&error);
    sd_bus_message_unref(reply);
}

void StatusTray::activate(const TrayIcon& icon, int x, int y) {
    if (icon.item_is_menu)
        context(icon, x, y);
    else
        call_item(icon, "Activate", "ii", x, y, nullptr);
}

void StatusTray::secondary(const TrayIcon& icon, int x, int y) {
    call_item(icon, "SecondaryActivate", "ii", x, y, nullptr);
}

void StatusTray::context(const TrayIcon& icon, int x, int y) {
    call_item(icon, "ContextMenu", "ii", x, y, nullptr);
}

void StatusTray::scroll(const TrayIcon& icon, int delta, const char* orientation) {
    call_item(icon, "Scroll", "is", delta, 0, orientation ? orientation : "vertical");
}
