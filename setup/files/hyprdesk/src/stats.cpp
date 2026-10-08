#include "logic.hpp"

#include <ctime>
#include <fstream>
#include <sstream>

namespace {

std::optional<uint64_t> meminfo_kb(const std::string& key) {
    std::ifstream file("/proc/meminfo");
    std::string   line;
    while (std::getline(file, line)) {
        if (line.rfind(key, 0) != 0)
            continue;
        std::istringstream input(line.substr(key.size()));
        uint64_t           value = 0;
        if (input >> value)
            return value;
    }
    return std::nullopt;
}

std::string default_iface() {
    std::ifstream file("/proc/net/route");
    std::string   line;
    std::getline(file, line);
    while (std::getline(file, line)) {
        std::istringstream input(line);
        std::string        iface;
        std::string        destination;
        if (!(input >> iface >> destination))
            continue;
        if (destination == "00000000")
            return iface;
    }
    return "";
}

std::string read_line_file(const std::string& path) {
    std::ifstream file(path);
    std::string   line;
    std::getline(file, line);
    while (!line.empty() && (line.back() == '\n' || line.back() == ' '))
        line.pop_back();
    return line;
}

} // namespace

std::optional<CpuSample> read_cpu_sample() {
    std::ifstream file("/proc/stat");
    std::string   cpu;
    uint64_t      user = 0, nice = 0, system = 0, idle = 0;
    if (!(file >> cpu >> user >> nice >> system >> idle))
        return std::nullopt;
    if (cpu != "cpu")
        return std::nullopt;
    CpuSample sample;
    sample.idle  = idle;
    sample.total = user + nice + system + idle;
    return sample;
}

int cpu_percent(const CpuSample& earlier, const CpuSample& later) {
    const auto total = later.total > earlier.total ? later.total - earlier.total : 0;
    const auto idle  = later.idle > earlier.idle ? later.idle - earlier.idle : 0;
    if (total == 0)
        return 0;
    return static_cast<int>((100 * (total - idle)) / total);
}

StatsText read_stats(const std::optional<CpuSample>& earlier) {
    StatsText stats;
    if (auto now = read_cpu_sample(); now && earlier)
        stats.cpu = "cpu " + std::to_string(cpu_percent(*earlier, *now)) + "%";

    if (auto total = meminfo_kb("MemTotal:"); total && *total > 0) {
        const auto avail = meminfo_kb("MemAvailable:").value_or(0);
        const auto used  = *total > avail ? (*total - avail) / 1024 / 1024 : 0;
        const auto whole = *total / 1024 / 1024;
        const auto tenth = ((*total / 1024) % 1024) * 10 / 1024;
        stats.mem        = "mem " + std::to_string(used) + "/" + std::to_string(whole) + "." + std::to_string(tenth) + "G";
    }

    std::string gpu_out;
    if (run_capture({"nvidia-smi", "--query-gpu=utilization.gpu,temperature.gpu", "--format=csv,noheader,nounits"}, gpu_out) == 0) {
        auto comma = gpu_out.find(',');
        if (comma != std::string::npos) {
            auto util = gpu_out.substr(0, comma);
            auto temp = gpu_out.substr(comma + 1);
            while (!util.empty() && util.back() == ' ')
                util.pop_back();
            while (!temp.empty() && (temp.back() == '\n' || temp.back() == ' '))
                temp.pop_back();
            while (!temp.empty() && temp.front() == ' ')
                temp.erase(temp.begin());
            stats.gpu = "gpu " + util + "% " + temp + "°";
        }
    } else {
        const auto busy = read_line_file("/sys/class/drm/card0/device/gpu_busy_percent");
        if (!busy.empty())
            stats.gpu = "gpu " + busy + "%";
    }

    const auto iface = default_iface();
    if (iface.empty()) {
        stats.net = "eth --";
    } else {
        std::string ssid;
        if (run_capture({"iwgetid", "-r"}, ssid) == 0) {
            while (!ssid.empty() && (ssid.back() == '\n' || ssid.back() == '\r'))
                ssid.pop_back();
        }
        if (!ssid.empty())
            stats.net = "eth " + ssid;
        else
            stats.net = "eth " + iface + " " + read_line_file("/sys/class/net/" + iface + "/operstate");
    }

    const auto now = std::time(nullptr);
    std::tm    local{};
    localtime_r(&now, &local);
    char       clock[16];
    char       date[16];
    std::strftime(clock, sizeof(clock), "%H:%M:%S", &local);
    std::strftime(date, sizeof(date), "%Y-%m-%d", &local);
    stats.clock = clock;
    stats.date  = date;
    return stats;
}
