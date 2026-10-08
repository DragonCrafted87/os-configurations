#include "logic.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace {

std::string lower_copy(std::string text) {
    for (char& c : text)
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return text;
}

std::string trim(const std::string& text) {
    size_t start = 0;
    while (start < text.size() && std::isspace(static_cast<unsigned char>(text[start])))
        ++start;
    size_t end = text.size();
    while (end > start && std::isspace(static_cast<unsigned char>(text[end - 1])))
        --end;
    return text.substr(start, end - start);
}

bool truthy(const std::string& value) {
    const auto text = lower_copy(trim(value));
    return text == "true" || text == "1";
}

std::vector<std::string> split_semi(const std::string& value) {
    std::vector<std::string> parts;
    std::string              current;
    for (char c : value) {
        if (c == ';') {
            current = trim(current);
            if (!current.empty())
                parts.push_back(current);
            current.clear();
        } else {
            current.push_back(c);
        }
    }
    current = trim(current);
    if (!current.empty())
        parts.push_back(current);
    return parts;
}

std::string unescape_desktop(const std::string& value) {
    std::string out;
    for (size_t i = 0; i < value.size(); ++i) {
        if (value[i] == '\\' && i + 1 < value.size()) {
            out.push_back(value[i + 1]);
            ++i;
            continue;
        }
        out.push_back(value[i]);
    }
    return out;
}

} // namespace

std::optional<DesktopEntry> parse_desktop_text(const std::string& id, const std::string& path, const std::string& text) {
    DesktopEntry entry;
    entry.id   = id;
    entry.path = path;
    bool in_entry = false;
    bool seen     = false;
    std::istringstream lines(text);
    std::string        line;
    while (std::getline(lines, line)) {
        if (!line.empty() && line.back() == '\r')
            line.pop_back();
        line = trim(line);
        if (line.empty() || line[0] == '#')
            continue;
        if (line.front() == '[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if (!in_entry)
            continue;
        auto eq = line.find('=');
        if (eq == std::string::npos)
            continue;
        const auto key   = line.substr(0, eq);
        const auto value = unescape_desktop(line.substr(eq + 1));
        seen             = true;
        if (key == "Type")
            entry.application = value == "Application";
        else if (key == "Name" && entry.name.empty())
            entry.name = value;
        else if (key == "GenericName" && entry.generic_name.empty())
            entry.generic_name = value;
        else if (key == "Comment" && entry.comment.empty())
            entry.comment = value;
        else if (key == "Exec" && entry.exec.empty())
            entry.exec = value;
        else if (key == "Icon" && entry.icon.empty())
            entry.icon = value;
        else if (key == "StartupWMClass" && entry.startup_class.empty())
            entry.startup_class = value;
        else if (key == "Categories")
            entry.categories = split_semi(value);
        else if (key == "Keywords")
            entry.keywords = split_semi(value);
        else if (key == "NoDisplay")
            entry.no_display = truthy(value);
        else if (key == "Hidden")
            entry.hidden = truthy(value);
    }
    if (!seen || !entry.application)
        return std::nullopt;
    if (entry.name.empty())
        entry.name = id;
    return entry;
}

std::string search_blob(const DesktopEntry& entry) {
    std::ostringstream blob;
    blob << entry.name << ' ' << entry.generic_name << ' ' << entry.comment << ' ' << entry.id;
    for (const auto& keyword : entry.keywords)
        blob << ' ' << keyword;
    return lower_copy(blob.str());
}

std::vector<DesktopEntry> filter_apps(const std::vector<DesktopEntry>& apps, const std::string& category, const std::string& query) {
    const auto             needle = lower_copy(query);
    std::vector<DesktopEntry> matched;
    for (const auto& app : apps) {
        if (app.no_display || app.hidden || !app.application)
            continue;
        if (!category.empty() && category != "*") {
            if (std::find(app.categories.begin(), app.categories.end(), category) == app.categories.end())
                continue;
        }
        if (!needle.empty() && search_blob(app).find(needle) == std::string::npos)
            continue;
        matched.push_back(app);
    }
    std::sort(matched.begin(), matched.end(), [](const DesktopEntry& a, const DesktopEntry& b) { return a.name < b.name; });
    return matched;
}

std::vector<std::string> entry_needles(const DesktopEntry& entry) {
    const auto id      = lower_copy(entry.id);
    const auto dot     = id.rfind('.');
    const auto last    = dot == std::string::npos ? id : id.substr(dot + 1);
    const auto name    = lower_copy(entry.name);
    const auto startup = lower_copy(entry.startup_class);
    std::vector<std::string> needles;
    for (const auto& needle : {startup, id, last, name}) {
        if (needle.size() > 1)
            needles.push_back(needle);
    }
    const auto blob = lower_copy(id + " " + startup + " " + name + " " + entry.icon);
    if (blob.find("vscode") != std::string::npos || blob.find("visual studio code") != std::string::npos) {
        needles.push_back("code");
        needles.push_back("code-url-handler");
        needles.push_back("com.microsoft.vscode");
    }
    return needles;
}

bool class_matches_needle(const std::string& klass, const std::string& needle) {
    const auto hay = lower_copy(klass);
    const auto pin = lower_copy(needle);
    if (hay.empty() || pin.empty())
        return false;
    if (hay == pin)
        return true;
    return pin.size() >= 4 && hay.find(pin) != std::string::npos;
}

std::string strip_exec_field_codes(const std::string& exec) {
    std::string out;
    for (size_t i = 0; i < exec.size(); ++i) {
        if (exec[i] == '%' && i + 1 < exec.size()) {
            const char code = exec[i + 1];
            if (code == '%') {
                out.push_back('%');
                ++i;
                continue;
            }
            if (std::strchr("fFuUdDnNickvm", code) != nullptr) {
                ++i;
                continue;
            }
        }
        out.push_back(exec[i]);
    }
    return out;
}

std::vector<std::string> split_exec(const std::string& exec) {
    const auto               cleaned = strip_exec_field_codes(exec);
    std::vector<std::string> args;
    std::string              current;
    bool                     quote = false;
    for (size_t i = 0; i < cleaned.size(); ++i) {
        const char c = cleaned[i];
        if (c == '"') {
            quote = !quote;
            continue;
        }
        if (!quote && std::isspace(static_cast<unsigned char>(c))) {
            if (!current.empty()) {
                args.push_back(current);
                current.clear();
            }
            continue;
        }
        current.push_back(c);
    }
    if (!current.empty())
        args.push_back(current);
    return args;
}

std::vector<DesktopEntry> load_desktop_entries() {
    std::vector<std::filesystem::path> roots;
    if (const char* home = std::getenv("HOME"))
        roots.emplace_back(std::filesystem::path(home) / ".local/share/applications");
    std::string data_dirs = "/usr/local/share:/usr/share";
    if (const char* env = std::getenv("XDG_DATA_DIRS"); env && *env)
        data_dirs = env;
    std::stringstream dirs(data_dirs);
    std::string       dir;
    while (std::getline(dirs, dir, ':')) {
        if (!dir.empty())
            roots.emplace_back(std::filesystem::path(dir) / "applications");
    }

    std::vector<DesktopEntry> entries;
    std::vector<std::string>  seen;
    for (const auto& root : roots) {
        std::error_code error;
        if (!std::filesystem::is_directory(root, error))
            continue;
        for (const auto& item : std::filesystem::directory_iterator(root, error)) {
            if (error || !item.is_regular_file(error))
                continue;
            if (item.path().extension() != ".desktop")
                continue;
            const auto id = item.path().filename().string();
            if (std::find(seen.begin(), seen.end(), id) != seen.end())
                continue;
            std::ifstream file(item.path());
            if (!file)
                continue;
            std::stringstream buffer;
            buffer << file.rdbuf();
            auto parsed = parse_desktop_text(id, item.path().string(), buffer.str());
            if (!parsed)
                continue;
            seen.push_back(id);
            entries.push_back(*parsed);
        }
    }
    return entries;
}
