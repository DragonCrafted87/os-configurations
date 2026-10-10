#include "logic.hpp"
#include "ui.hpp"

#ifndef HYPRDESK_VERSION
#define HYPRDESK_VERSION "1"
#endif

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <thread>

namespace {

bool send_command_once(const std::string& command) {
    const int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return false;
    const auto  path = desk_socket_path();
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path)) {
        close(fd);
        return false;
    }
    std::snprintf(address.sun_path, sizeof(address.sun_path), "%s", path.c_str());
    if (connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
        close(fd);
        return false;
    }
    const auto line = command + "\n";
    (void)write(fd, line.data(), line.size());
    close(fd);
    return true;
}

bool send_command(const std::string& command) {
    for (int attempt = 0; attempt < 10; ++attempt) {
        if (send_command_once(command))
            return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return false;
}

} // namespace

int main(int argc, char** argv) {
    bool        daemon  = false;
    bool        open    = false;
    std::string command;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--version" || arg == "-v") {
            std::puts("Hyprdesk " HYPRDESK_VERSION);
            return 0;
        }
        if (arg == "--self-test")
            return run_self_test() ? 0 : 1;
        if (arg == "-d" || arg == "--daemon")
            daemon = true;
        else if (arg == "--toggle")
            command = "toggle";
        else if (arg == "--open")
            command = "open";
        else if (arg == "--close")
            command = "close";
        else {
            std::fprintf(stderr, "Usage: hyprdesk [-d] [--toggle|--open|--close|--version|--self-test]\n");
            return 1;
        }
    }
    if (!command.empty() && send_command(command))
        return 0;
    if (command == "close") {
        std::fprintf(stderr, "hyprdesk is not running\n");
        return 1;
    }
    open = command == "toggle" || command == "open";
    if (!daemon && !open && !command.empty())
        return 1;
    return run_daemon(open);
}
