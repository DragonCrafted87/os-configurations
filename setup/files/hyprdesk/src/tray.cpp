#include "tray.hpp"

#include <systemd/sd-bus.h>

#include <cairo/cairo.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

struct StatusTray::Bus {
    sd_bus*      bus       = nullptr;
    sd_bus_slot* slot      = nullptr;
    sd_bus_slot* name_slot = nullptr;
    sd_bus_slot* icon_slot = nullptr;
    int          fd        = -1;
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

int on_new_icon(sd_bus_message* message, void* userdata, sd_bus_error*) {
    const char* sender = sd_bus_message_get_sender(message);
    const char* path   = sd_bus_message_get_path(message);
    static_cast<StatusTray*>(userdata)->reload_icon(sender ? sender : "", path ? path : "");
    return 0;
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
    auto* tray = static_cast<StatusTray*>(userdata);
    if (name && *name)
        tray->drop_service(name);
    if (old_owner && *old_owner)
        tray->drop_service(old_owner);
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
    sd_bus_slot_unref(m_bus->icon_slot);
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
    sd_bus_add_match(bus->bus, &bus->icon_slot, "type='signal',interface='org.kde.StatusNotifierItem',member='NewIcon'", on_new_icon, this);
    bus->fd = sd_bus_get_fd(bus->bus);
    m_bus   = bus;
    announce();
    return true;
}

void StatusTray::process() {
    if (!m_bus)
        return;
    while (sd_bus_process(m_bus->bus, nullptr) > 0) {
    }
}

void StatusTray::announce() {
    if (!m_bus)
        return;
    sd_bus_emit_signal(m_bus->bus, "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "StatusNotifierHostRegistered", "");
}

int StatusTray::fd() const {
    return m_bus ? m_bus->fd : -1;
}

uint64_t StatusTray::generation() const {
    return m_generation;
}

const std::vector<TrayIcon>& StatusTray::items() const {
    return m_items;
}

int tray_popup_height(const std::vector<TrayMenuItem>& items) {
    constexpr int margin = 6;
    constexpr int gap    = 2;
    constexpr int row    = 28;
    if (items.empty())
        return margin * 2 + row;
    int body = 0;
    for (size_t index = 0; index < items.size(); ++index) {
        if (index > 0)
            body += gap;
        body += items[index].separator ? 1 : row;
    }
    return margin * 2 + body;
}

std::vector<uint8_t> argb_to_png(int width, int height, const uint8_t* pixels, size_t size) {
    if (width <= 0 || height <= 0 || width > 256 || height > 256 || !pixels)
        return {};
    const size_t need = static_cast<size_t>(width) * static_cast<size_t>(height) * 4U;
    if (size < need)
        return {};
    cairo_surface_t* surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return {};
    }
    unsigned char* dest   = cairo_image_surface_get_data(surface);
    const int      stride = cairo_image_surface_get_stride(surface);
    for (int y = 0; y < height; ++y) {
        auto*            row = reinterpret_cast<uint32_t*>(dest + static_cast<size_t>(y) * static_cast<size_t>(stride));
        const uint8_t*   src = pixels + static_cast<size_t>(y) * static_cast<size_t>(width) * 4U;
        for (int x = 0; x < width; ++x) {
            const uint8_t alpha = src[0];
            const uint8_t red   = static_cast<uint8_t>((static_cast<unsigned>(src[1]) * alpha) / 255U);
            const uint8_t green = static_cast<uint8_t>((static_cast<unsigned>(src[2]) * alpha) / 255U);
            const uint8_t blue  = static_cast<uint8_t>((static_cast<unsigned>(src[3]) * alpha) / 255U);
            row[x]              = (static_cast<uint32_t>(alpha) << 24) | (static_cast<uint32_t>(red) << 16) | (static_cast<uint32_t>(green) << 8) | static_cast<uint32_t>(blue);
            src += 4;
        }
    }
    cairo_surface_mark_dirty(surface);
    std::vector<uint8_t> png;
    const cairo_status_t status = cairo_surface_write_to_png_stream(
        surface,
        [](void* closure, const unsigned char* data, unsigned int length) -> cairo_status_t {
            auto* out = static_cast<std::vector<uint8_t>*>(closure);
            out->insert(out->end(), data, data + length);
            return CAIRO_STATUS_SUCCESS;
        },
        &png);
    cairo_surface_destroy(surface);
    if (status != CAIRO_STATUS_SUCCESS)
        return {};
    return png;
}

namespace {

std::vector<uint8_t> read_icon_png(sd_bus* bus, const TrayIcon& icon) {
    sd_bus_error    error = SD_BUS_ERROR_NULL;
    sd_bus_message* reply = nullptr;
    if (sd_bus_get_property(bus, icon.service.c_str(), icon.path.c_str(), "org.kde.StatusNotifierItem", "IconPixmap", &error, &reply, "a(iiay)") < 0) {
        sd_bus_error_free(&error);
        sd_bus_message_unref(reply);
        return {};
    }
    sd_bus_error_free(&error);
    if (sd_bus_message_enter_container(reply, 'a', "(iiay)") < 0) {
        sd_bus_message_unref(reply);
        return {};
    }
    int                  best_area = 0;
    std::vector<uint8_t> best;
    while (sd_bus_message_enter_container(reply, 'r', "iiay") > 0) {
        int width  = 0;
        int height = 0;
        if (sd_bus_message_read(reply, "ii", &width, &height) < 0) {
            sd_bus_message_exit_container(reply);
            break;
        }
        const void* bytes = nullptr;
        size_t      count = 0;
        if (sd_bus_message_read_array(reply, 'y', &bytes, &count) < 0) {
            sd_bus_message_exit_container(reply);
            break;
        }
        if (width > 0 && height > 0 && width <= 256 && height <= 256 && width * height > best_area) {
            auto png = argb_to_png(width, height, static_cast<const uint8_t*>(bytes), count);
            if (!png.empty()) {
                best_area = width * height;
                best      = std::move(png);
            }
        }
        sd_bus_message_exit_container(reply);
    }
    sd_bus_message_exit_container(reply);
    sd_bus_message_unref(reply);
    return best;
}

} // namespace

void StatusTray::read_item(TrayIcon& icon) {
    if (!m_bus)
        return;
    const auto   previous_icon = icon.icon;
    const auto   previous_png  = icon.icon_png;
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
        text = nullptr;
    }
    sd_bus_error_free(&error);
    error = SD_BUS_ERROR_NULL;
    if (sd_bus_get_property_string(m_bus->bus, icon.service.c_str(), icon.path.c_str(), "org.kde.StatusNotifierItem", "IconThemePath", &error, &text) >= 0 && text) {
        icon.icon_theme = text;
        free(text);
        text = nullptr;
    }
    sd_bus_error_free(&error);
    icon.icon_png = read_icon_png(m_bus->bus, icon);
    if (icon.icon != previous_icon || icon.icon_png != previous_png)
        ++m_generation;
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
        } else if (std::strcmp(key, "children-display") == 0 && contents[0] == 's') {
            const char* display = nullptr;
            if (sd_bus_message_read(message, "s", &display) >= 0 && display && std::strcmp(display, "submenu") == 0)
                item.submenu = true;
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
    if (!item.children.empty())
        item.submenu = true;
    sd_bus_message_exit_container(message);
    return true;
}

} // namespace

std::vector<TrayMenuItem> layout_children(sd_bus* bus, const TrayIcon& icon, int parent) {
    std::vector<TrayMenuItem> items;
    if (!bus || icon.menu_path.empty())
        return items;
    sd_bus_error    error = SD_BUS_ERROR_NULL;
    sd_bus_message* shown = nullptr;
    sd_bus_call_method(bus, icon.service.c_str(), icon.menu_path.c_str(), "com.canonical.dbusmenu", "AboutToShow", &error, &shown, "i", parent);
    sd_bus_error_free(&error);
    sd_bus_message_unref(shown);
    const char*     names[] = {"label", "type", "enabled", "visible", "children-display"};
    sd_bus_message* reply   = nullptr;
    error                   = SD_BUS_ERROR_NULL;
    sd_bus_message* call    = nullptr;
    if (sd_bus_message_new_method_call(bus, &call, icon.service.c_str(), icon.menu_path.c_str(), "com.canonical.dbusmenu", "GetLayout") < 0)
        return items;
    sd_bus_message_append(call, "ii", parent, -1);
    sd_bus_message_open_container(call, 'a', "s");
    for (const char* name : names)
        sd_bus_message_append(call, "s", name);
    sd_bus_message_close_container(call);
    if (sd_bus_call(bus, call, 0, &error, &reply) < 0) {
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
    if (parent != 0)
        return items;
    if (root.separator || !root.label.empty())
        items.push_back(std::move(root));
    return items;
}

std::vector<TrayMenuItem> StatusTray::menu_items(const TrayIcon& icon) {
    if (!m_bus)
        return {};
    return layout_children(m_bus->bus, icon, 0);
}

std::vector<TrayMenuItem> StatusTray::submenu_items(const TrayIcon& icon, int id) {
    if (!m_bus)
        return {};
    return layout_children(m_bus->bus, icon, id);
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

namespace {

std::string bus_name_owner(sd_bus* bus, const std::string& name) {
    if (name.empty())
        return {};
    if (name.front() == ':')
        return name;
    if (!bus)
        return {};
    sd_bus_error    error = SD_BUS_ERROR_NULL;
    sd_bus_message* reply = nullptr;
    const int       rc    = sd_bus_call_method(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", &error, &reply, "s",
                                               name.c_str());
    std::string     owner;
    if (rc >= 0 && reply) {
        const char* text = nullptr;
        if (sd_bus_message_read(reply, "s", &text) >= 0 && text)
            owner = text;
    }
    sd_bus_error_free(&error);
    sd_bus_message_unref(reply);
    return owner;
}

bool same_sni(const TrayIcon& icon, const std::string& service, const std::string& unique, const std::string& path) {
    if (icon.path != path)
        return false;
    if (icon.service == service || (!unique.empty() && (icon.unique == unique || icon.service == unique)))
        return true;
    return !icon.unique.empty() && icon.unique == service;
}

} // namespace

void StatusTray::register_item(const std::string& argument, const std::string& sender) {
    auto target = resolve_sni_target(argument, sender);
    if (target.service.empty() || target.path.empty())
        return;
    const std::string unique = bus_name_owner(m_bus ? m_bus->bus : nullptr, target.service);
    const std::string owner  = !unique.empty() ? unique : (sender.size() > 1 && sender.front() == ':' ? sender : std::string{});
    for (const auto& icon : m_items) {
        if (same_sni(icon, target.service, owner, target.path))
            return;
    }
    TrayIcon icon;
    icon.service = target.service;
    icon.unique  = owner;
    icon.path    = target.path;
    read_item(icon);
    m_items.push_back(icon);
    ++m_generation;
    if (m_bus)
        sd_bus_emit_signal(m_bus->bus, "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "StatusNotifierItemRegistered", "s", icon.service.c_str());
}

void StatusTray::reload_icon(const std::string& service, const std::string& path) {
    for (auto& icon : m_items) {
        if (icon.path == path && (icon.service == service || (!icon.unique.empty() && icon.unique == service))) {
            read_item(icon);
            return;
        }
    }
}

void StatusTray::drop_service(const std::string& service) {
    if (service.empty())
        return;
    const auto before = m_items.size();
    std::erase_if(m_items, [&](const TrayIcon& icon) { return icon.service == service || icon.unique == service; });
    if (m_items.size() != before) {
        ++m_generation;
        if (m_bus)
            sd_bus_emit_signal(m_bus->bus, "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "StatusNotifierItemUnregistered", "s", service.c_str());
    }
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
