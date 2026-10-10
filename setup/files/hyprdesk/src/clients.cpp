#include "logic.hpp"

#include <algorithm>
#include <cctype>

namespace {

std::vector<std::string> top_objects(const std::string& json) {
    std::vector<std::string> objects;
    int                      depth     = 0;
    int                      obj_depth = 0;
    size_t                   start     = 0;
    bool                     in_string = false;
    bool                     escape    = false;
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
        if (c == '{') {
            if (depth == 1) {
                start     = i;
                obj_depth = 1;
            } else if (obj_depth > 0) {
                ++obj_depth;
            }
            ++depth;
            continue;
        }
        if (c == '[') {
            ++depth;
            continue;
        }
        if (c == '}') {
            if (obj_depth > 0) {
                --obj_depth;
                if (obj_depth == 0)
                    objects.emplace_back(json.substr(start, i - start + 1));
            }
            if (depth > 0)
                --depth;
            continue;
        }
        if (c == ']' && depth > 0)
            --depth;
    }
    return objects;
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
    std::string out;
    for (size_t i = quote + 1; i < object.size(); ++i) {
        if (object[i] == '\\' && i + 1 < object.size()) {
            out.push_back(object[i + 1]);
            ++i;
            continue;
        }
        if (object[i] == '"')
            break;
        out.push_back(object[i]);
    }
    return out;
}

} // namespace

std::vector<Client> parse_clients(const std::string& json) {
    std::vector<Client> clients;
    for (const auto& object : top_objects(json)) {
        Client client;
        client.address       = field_string(object, "address");
        client.title         = field_string(object, "title");
        client.klass         = field_string(object, "class");
        client.initial_class = field_string(object, "initialClass");
        auto workspace       = object.find("\"workspace\"");
        if (workspace != std::string::npos)
            client.workspace = field_string(object.substr(workspace), "name");
        if (!client.address.empty())
            clients.push_back(client);
    }
    return clients;
}

bool is_minimized_workspace(const std::string& workspace) {
    return workspace.rfind("special", 0) == 0 || workspace.find("minimized") != std::string::npos;
}

bool safe_window_address(const std::string& address) {
    if (address.size() < 3 || address.size() > 32)
        return false;
    if (address[0] != '0' || (address[1] != 'x' && address[1] != 'X'))
        return false;
    for (size_t i = 2; i < address.size(); ++i) {
        if (!std::isxdigit(static_cast<unsigned char>(address[i])))
            return false;
    }
    return true;
}

std::vector<Client> windows_for_menu(const std::vector<Client>& all, bool minimized_only, bool& show_all) {
    std::vector<Client> usable;
    for (const auto& client : all) {
        if (safe_window_address(client.address))
            usable.push_back(client);
    }
    std::vector<Client> minimized;
    for (const auto& client : usable) {
        if (is_minimized_workspace(client.workspace))
            minimized.push_back(client);
    }
    show_all = false;
    std::vector<Client> chosen = usable;
    if (minimized_only) {
        if (minimized.empty()) {
            show_all = true;
            chosen   = usable;
        } else {
            chosen = minimized;
        }
    }
    std::sort(chosen.begin(), chosen.end(), [](const Client& a, const Client& b) {
        const auto& ca = a.initial_class.empty() ? a.klass : a.initial_class;
        const auto& cb = b.initial_class.empty() ? b.klass : b.initial_class;
        if (ca != cb)
            return ca < cb;
        return a.title < b.title;
    });
    return chosen;
}

SniTarget resolve_sni_target(const std::string& argument, const std::string& sender) {
    SniTarget target;
    if (!argument.empty() && argument.front() == '/') {
        target.service = sender;
        target.path    = argument;
    } else {
        target.service = argument;
        target.path    = "/StatusNotifierItem";
    }
    return target;
}

DeskCommand parse_command(const std::string& line) {
    std::string command = line;
    while (!command.empty() && (command.back() == '\n' || command.back() == '\r' || command.back() == ' '))
        command.pop_back();
    if (command == "toggle")
        return DeskCommand::Toggle;
    if (command == "open")
        return DeskCommand::Open;
    if (command == "close")
        return DeskCommand::Close;
    return DeskCommand::Unknown;
}
