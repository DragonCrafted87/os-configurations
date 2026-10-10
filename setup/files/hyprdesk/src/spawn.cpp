#include "logic.hpp"

#include <cerrno>
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <sys/socket.h>
#include <sys/un.h>

#include <cstring>
#include <vector>

extern char** environ;

namespace {

std::vector<char*> argv_of(const std::vector<std::string>& args) {
    std::vector<char*> pointers;
    pointers.reserve(args.size() + 1);
    for (const auto& arg : args)
        pointers.push_back(const_cast<char*>(arg.c_str()));
    pointers.push_back(nullptr);
    return pointers;
}

} // namespace

std::string desk_socket_path() {
    if (const char* runtime = std::getenv("XDG_RUNTIME_DIR"); runtime && *runtime)
        return std::string(runtime) + "/hyprdesk.sock";
    return "/tmp/hyprdesk-" + std::to_string(getuid()) + ".sock";
}

int acquire_server_socket() {
    const auto  path = desk_socket_path();
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path))
        return -1;
    std::snprintf(address.sun_path, sizeof(address.sun_path), "%s", path.c_str());

    const int probe = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (probe >= 0 && connect(probe, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0) {
        close(probe);
        return -1;
    }
    if (probe >= 0)
        close(probe);

    unlink(path.c_str());
    const int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;
    if (bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 || listen(fd, 8) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int run_capture(const std::vector<std::string>& args, std::string& output) {
    output.clear();
    if (args.empty())
        return 1;
    int pipes[2] = {-1, -1};
    if (pipe(pipes) != 0)
        return 1;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipes[0]);
    posix_spawn_file_actions_addclose(&actions, pipes[1]);
    pid_t pid    = 0;
    auto  copied = argv_of(args);
    int   status = posix_spawnp(&pid, copied[0], &actions, nullptr, copied.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipes[1]);
    if (status != 0) {
        close(pipes[0]);
        return status;
    }
    char    buffer[4096];
    ssize_t got = 0;
    while ((got = read(pipes[0], buffer, sizeof(buffer))) > 0)
        output.append(buffer, static_cast<size_t>(got));
    close(pipes[0]);
    int wait_status = 0;
    waitpid(pid, &wait_status, 0);
    if (WIFEXITED(wait_status))
        return WEXITSTATUS(wait_status);
    return 1;
}

void run_detached(const std::vector<std::string>& args) {
    if (args.empty())
        return;
    int status = 0;
    while (waitpid(-1, &status, WNOHANG) > 0) {
    }
    // fork() from this process deadlocks: the volume thread can hold a
    // lock the child needs before posix_spawnp. Spawn from this thread.
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDWR, 0);
    posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
#ifdef POSIX_SPAWN_SETSID
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
#endif
    pid_t pid     = 0;
    auto  copied  = argv_of(args);
    posix_spawnp(&pid, copied[0], &actions, &attr, copied.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
}
