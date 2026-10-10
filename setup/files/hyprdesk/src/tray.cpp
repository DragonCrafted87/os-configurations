#include "tray.hpp"

#include <systemd/sd-bus.h>

#include <chrono>
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
    sd_bus_message* path_reply = nullptr;
    error                      = SD_BUS_ERROR_NULL;
    if (sd_bus_get_property(m_bus->bus, icon.service.c_str(), icon.path.c_str(), "org.kde.StatusNotifierItem", "Menu", &error, &path_reply, "o") >= 0 && path_reply) {
        const char* path = nullptr;
        if (sd_bus_message_read(path_reply, "o", &path) >= 0 && path)
            icon.menu_path = path;
    }
    sd_bus_error_free(&error);
    sd_bus_message_unref(path_reply);
}

namespace {

bool read_menu_item(sd_bus_message* message, TrayMenuItem& item) {
    if (sd_bus_message_enter_container(message, 'r', "ia{sv}av") < 0)
        return false;
    if (sd_bus_message_read(message, "i", &item.id) < 0) {
        sd_bus_message_exit_container(message);
        return false;
    }
    if (sd_bus_message_enter_container(message, 'a', "{sv}") < 0) {
        sd_bus_message_exit_container(message);
        return false;
    }
    while (sd_bus_message_enter_container(message, 'e', "sv") > 0) {
        const char* key = nullptr;
        if (sd_bus_message_read(message, "s", &key) < 0) {
            sd_bus_message_exit_container(message);
            break;
        }
        const char* contents = nullptr;
        if (sd_bus_message_peek_type(message, nullptr, &contents) < 0 || !contents) {
            sd_bus_message_exit_container(message);
            break;
        }
        if (sd_bus_message_enter_container(message, 'v', contents) < 0) {
            sd_bus_message_exit_container(message);
            break;
        }
        if (std::strcmp(key, "label") == 0 && contents[0] == 's') {
            const char* label = nullptr;
            if (sd_bus_message_read(message, "s", &label) >= 0 && label)
                item.label = label;
        } else if (std::strcmp(key, "type") == 0 && contents[0] == 's') {
            const char* type = nullptr;
            if (sd_bus_message_read(message, "s", &type) >= 0 && type && std::strcmp(type, "separator") == 0)
                item.separator = true;
        } else if (std::strcmp(key, "enabled") == 0 && contents[0] == 'b') {
            int enabled = 1;
            if (sd_bus_message_read(message, "b", &enabled) >= 0)
                item.enabled = enabled != 0;
        } else if (std::strcmp(key, "visible") == 0 && contents[0] == 'b') {
            int visible = 1;
            if (sd_bus_message_read(message, "b", &visible) >= 0 && visible == 0)
                item.label.clear();
        } else {
            sd_bus_message_skip(message, contents);
        }
        sd_bus_message_exit_container(message);
        sd_bus_message_exit_container(message);
    }
    sd_bus_message_exit_container(message);
    if (sd_bus_message_enter_container(message, 'a', "v") >= 0) {
        while (sd_bus_message_enter_container(message, 'v', "(ia{sv}av)") > 0) {
            TrayMenuItem child;
            if (read_menu_item(message, child) && (child.separator || !child.label.empty() || !child.children.empty()))
                item.children.push_back(std::move(child));
            sd_bus_message_exit_container(message);
        }
        sd_bus_message_exit_container(message);
    }
    sd_bus_message_exit_container(message);
    return true;
}

} // namespace

std::vector<TrayMenuItem> StatusTray::menu_items(const TrayIcon& icon) {
    std::vector<TrayMenuItem> items;
    if (!m_bus || icon.menu_path.empty())
        return items;
    sd_bus_error    error = SD_BUS_ERROR_NULL;
    sd_bus_message* shown = nullptr;
    sd_bus_call_method(m_bus->bus, icon.service.c_str(), icon.menu_path.c_str(), "com.canonical.dbusmenu", "AboutToShow", &error, &shown, "i", 0);
    sd_bus_error_free(&error);
    sd_bus_message_unref(shown);
    const char*     names[] = {"label", "type", "enabled", "visible"};
    sd_bus_message* reply   = nullptr;
    error                   = SD_BUS_ERROR_NULL;
    sd_bus_message* call    = nullptr;
    if (sd_bus_message_new_method_call(m_bus->bus, &call, icon.service.c_str(), icon.menu_path.c_str(), "com.canonical.dbusmenu", "GetLayout") < 0)
        return items;
    sd_bus_message_append(call, "ii", 0, -1);
    sd_bus_message_open_container(call, 'a', "s");
    for (const char* name : names)
        sd_bus_message_append(call, "s", name);
    sd_bus_message_close_container(call);
    if (sd_bus_call(m_bus->bus, call, 0, &error, &reply) < 0) {
        sd_bus_message_unref(call);
        sd_bus_error_free(&error);
        return items;
    }
    sd_bus_message_unref(call);
    uint32_t     revision = 0;
    TrayMenuItem root;
    if (sd_bus_message_read(reply, "u", &revision) >= 0)
        read_menu_item(reply, root);
    sd_bus_error_free(&error);
    sd_bus_message_unref(reply);
    if (!root.children.empty())
        return root.children;
    if (root.separator || !root.label.empty())
        items.push_back(std::move(root));
    return items;
}

void StatusTray::activate_menu_item(const TrayIcon& icon, int id) {
    if (!m_bus || icon.menu_path.empty())
        return;
    sd_bus_error    error = SD_BUS_ERROR_NULL;
    sd_bus_message* shown = nullptr;
    sd_bus_call_method(m_bus->bus, icon.service.c_str(), icon.menu_path.c_str(), "com.canonical.dbusmenu", "AboutToShow", &error, &shown, "i", id);
    sd_bus_error_free(&error);
    sd_bus_message_unref(shown);
    sd_bus_message* call  = nullptr;
    sd_bus_message* reply = nullptr;
    error                 = SD_BUS_ERROR_NULL;
    if (sd_bus_message_new_method_call(m_bus->bus, &call, icon.service.c_str(), icon.menu_path.c_str(), "com.canonical.dbusmenu", "Event") < 0)
        return;
    // KDE Connect ignores a clicked event whose data variant is an int.
    sd_bus_message_append(call, "is", id, "clicked");
    sd_bus_message_open_container(call, 'v', "s");
    sd_bus_message_append(call, "s", "");
    sd_bus_message_close_container(call);
    const auto now = static_cast<uint32_t>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
    sd_bus_message_append(call, "u", now);
    sd_bus_call(m_bus->bus, call, 0, &error, &reply);
    sd_bus_message_unref(call);
    sd_bus_message_unref(reply);
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
