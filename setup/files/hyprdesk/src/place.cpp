#include "logic.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>

namespace {

std::optional<double> field_number(const std::string& object, const std::string& key) {
    const std::string pattern = "\"" + key + "\"";
    const auto        at      = object.find(pattern);
    if (at == std::string::npos)
        return std::nullopt;
    auto colon = object.find(':', at + pattern.size());
    if (colon == std::string::npos)
        return std::nullopt;
    size_t i = colon + 1;
    while (i < object.size() && std::isspace(static_cast<unsigned char>(object[i])))
        ++i;
    try {
        size_t used = 0;
        double value = std::stod(object.substr(i), &used);
        if (used == 0)
            return std::nullopt;
        return value;
    } catch (const std::exception&) {
        return std::nullopt;
    }
}

std::string field_string(const std::string& object, const std::string& key) {
    const std::string pattern = "\"" + key + "\"";
    const auto        at      = object.find(pattern);
    if (at == std::string::npos)
        return "";
    auto colon = object.find(':', at + pattern.size());
    if (colon == std::string::npos)
        return "";
    auto quote = object.find('"', colon + 1);
    if (quote == std::string::npos)
        return "";
    auto end = object.find('"', quote + 1);
    if (end == std::string::npos)
        return "";
    return object.substr(quote + 1, end - quote - 1);
}

bool field_bool(const std::string& object, const std::string& key) {
    const std::string pattern = "\"" + key + "\"";
    const auto        at      = object.find(pattern);
    if (at == std::string::npos)
        return false;
    auto colon = object.find(':', at + pattern.size());
    if (colon == std::string::npos)
        return false;
    size_t i = colon + 1;
    while (i < object.size() && std::isspace(static_cast<unsigned char>(object[i])))
        ++i;
    return object.compare(i, 4, "true") == 0;
}

std::vector<std::string> top_objects(const std::string& json) {
    std::vector<std::string> objects;
    int                      depth      = 0;
    int                      obj_depth  = 0;
    size_t                   start      = 0;
    bool                     in_string  = false;
    bool                     escape     = false;
    for (size_t i = 0; i < json.size(); ++i) {
        const char c = json[i];
        if (in_string) {
            if (escape)
                escape = false;
            else if (c == '\\')
                escape = true;
            else if (c == '"')
                in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == '{' || c == '[') {
            if (c == '{' && depth == 1) {
                start     = i;
                obj_depth = 1;
            } else if (c == '{' && obj_depth > 0) {
                ++obj_depth;
            }
            ++depth;
            continue;
        }
        if (c == '}' || c == ']') {
            if (c == '}' && obj_depth > 0) {
                --obj_depth;
                if (obj_depth == 0)
                    objects.emplace_back(json.substr(start, i - start + 1));
            }
            if (depth > 0)
                --depth;
        }
    }
    return objects;
}

} // namespace

const char* hyprctl_bin() {
    return "/usr/local/bin/hyprctl";
}

int menu_width_for(int monitor_w) {
    const int scaled = static_cast<int>(std::lround(monitor_w * 0.22));
    return std::max(380, std::min(460, scaled));
}

bool parse_cursor_pos(const std::string& line, int& x, int& y) {
    auto comma = line.find(',');
    if (comma == std::string::npos)
        return false;
    try {
        x = std::stoi(line.substr(0, comma));
        y = std::stoi(line.substr(comma + 1));
    } catch (const std::exception&) {
        return false;
    }
    return true;
}

std::vector<Monitor> parse_monitors(const std::string& json) {
    std::vector<Monitor> monitors;
    for (const auto& object : top_objects(json)) {
        Monitor monitor;
        if (auto value = field_number(object, "x"))
            monitor.x = static_cast<int>(*value);
        if (auto value = field_number(object, "y"))
            monitor.y = static_cast<int>(*value);
        if (auto value = field_number(object, "width"))
            monitor.width = static_cast<int>(*value);
        if (auto value = field_number(object, "height"))
            monitor.height = static_cast<int>(*value);
        monitor.focused = field_bool(object, "focused");
        auto workspace   = object.find("\"activeWorkspace\"");
        const auto head  = workspace == std::string::npos ? object : object.substr(0, workspace);
        monitor.name     = field_string(head, "name");
        if (workspace != std::string::npos) {
            const auto block = object.substr(workspace);
            if (auto id = field_number(block, "id"))
                monitor.workspace = static_cast<int>(*id);
            const auto name = field_string(block, "name");
            if (!name.empty())
                monitor.workspace_name = name;
            else
                monitor.workspace_name = std::to_string(monitor.workspace);
        }
        if (monitor.width <= 0)
            monitor.width = 1920;
        if (monitor.height <= 0)
            monitor.height = 1080;
        monitors.push_back(monitor);
    }
    return monitors;
}

Placement place_menu(int cursor_x, int cursor_y, const std::vector<Monitor>& monitors, int menu_h) {
    Placement place;
    place.menu_h = std::max(280, menu_h);
    const Monitor* monitor = nullptr;
    for (const auto& candidate : monitors) {
        if (cursor_x >= candidate.x && cursor_x < candidate.x + candidate.width && cursor_y >= candidate.y && cursor_y < candidate.y + candidate.height) {
            monitor = &candidate;
            break;
        }
    }
    if (!monitor) {
        for (const auto& candidate : monitors) {
            if (candidate.focused) {
                monitor = &candidate;
                break;
            }
        }
    }
    if (!monitor && !monitors.empty())
        monitor = &monitors.front();
    if (!monitor)
        return place;

    place.monitor_w    = monitor->width;
    place.monitor_h    = monitor->height;
    place.monitor_x    = monitor->x;
    place.monitor_y    = monitor->y;
    place.monitor_name = monitor->name;
    place.workspace = monitor->workspace;
    place.workspace_name = monitor->workspace_name.empty() ? std::to_string(monitor->workspace) : monitor->workspace_name;
    place.menu_w    = menu_width_for(monitor->width);
    place.menu_h    = std::max(280, std::min(std::max(280, monitor->height - 16), place.menu_h));

    int left = cursor_x - monitor->x;
    int top  = cursor_y - monitor->y;
    if (left + place.menu_w > monitor->width)
        left = std::max(8, monitor->width - place.menu_w - 8);
    if (top + place.menu_h > monitor->height)
        top = std::max(8, monitor->height - place.menu_h - 8);
    if (left < 0)
        left = 8;
    if (top < 0)
        top = 8;
    place.menu_left = left;
    place.menu_top  = top;
    place.flyout_on_left = (left + place.menu_w + place.flyout_gap + place.flyout_w) > (monitor->width - 8);
    if (place.flyout_on_left)
        place.flyout_left = std::max(8, left - place.flyout_w - place.flyout_gap);
    else
        place.flyout_left = left + place.menu_w + place.flyout_gap;
    return place;
}

int window_block_height(int count) {
    if (count <= 0)
        return kMenuWindowEmpty;
    const int rows = std::min(count, kMenuWindowCap);
    return (rows * kMenuWindowRow) + ((rows - 1) * kMenuWindowGap);
}

int menu_height_for(int window_rows) {
    return kMenuChrome + kMenuCategoryBlock + window_block_height(window_rows);
}

MenuBands menu_bands(int menu_h, int window_count) {
    const int budget  = std::max(1, menu_h - kMenuChrome);
    const int top_nat = kMenuCategoryBlock;
    const int win_nat = window_block_height(window_count);
    MenuBands bands;
    if (budget >= top_nat) {
        bands.top     = top_nat;
        bands.windows = std::min(win_nat, budget - top_nat);
        return bands;
    }
    constexpr int win_floor = 28;
    bands.windows           = std::min(win_nat, win_floor);
    if (bands.windows >= budget)
        bands.windows = std::max(0, budget - 1);
    bands.top = std::max(1, budget - bands.windows);
    return bands;
}

void fit_menu_width(Placement& place, int content_w) {
    if (content_w > place.menu_w)
        place.menu_w = std::min(place.monitor_w - 16, content_w);
    if (place.menu_w < 1)
        place.menu_w = 1;
    if (place.menu_left + place.menu_w > place.monitor_w - 8)
        place.menu_left = std::max(8, place.monitor_w - place.menu_w - 8);
    place.flyout_on_left = (place.menu_left + place.menu_w + place.flyout_gap + place.flyout_w) > (place.monitor_w - 8);
    if (place.flyout_on_left)
        place.flyout_left = std::max(8, place.menu_left - place.flyout_w - place.flyout_gap);
    else
        place.flyout_left = place.menu_left + place.menu_w + place.flyout_gap;
}

Anchor clamp_on_output(int global_x, int global_y, int width, int height, const std::vector<Monitor>& monitors) {
    const Monitor* monitor = nullptr;
    for (const auto& candidate : monitors) {
        if (global_x >= candidate.x && global_x < candidate.x + candidate.width && global_y >= candidate.y && global_y < candidate.y + candidate.height) {
            monitor = &candidate;
            break;
        }
    }
    if (!monitor) {
        for (const auto& candidate : monitors) {
            if (candidate.focused) {
                monitor = &candidate;
                break;
            }
        }
    }
    if (!monitor && !monitors.empty())
        monitor = &monitors.front();
    Anchor anchor;
    if (!monitor)
        return anchor;
    int left = global_x - monitor->x;
    int top  = global_y - monitor->y;
    if (left + width > monitor->width)
        left = std::max(8, monitor->width - width - 8);
    if (top + height > monitor->height)
        top = std::max(8, monitor->height - height - 8);
    if (left < 0)
        left = 8;
    if (top < 0)
        top = 8;
    anchor.left = left;
    anchor.top  = top;
    return anchor;
}
