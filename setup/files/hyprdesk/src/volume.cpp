#include "logic.hpp"

#include <cmath>
#include <sstream>

namespace {

constexpr double kStep = 0.025;
constexpr double kMax  = 1.5;

double round_to(double value, double step) {
    return std::round(value / step) * step;
}

// wpctl prints two decimals, so a 0.725 sink comes back as 0.73.
std::string format_step_percent(double level) {
    const int steps  = static_cast<int>(std::lround(snap_volume(level) / kStep));
    const int tenths = steps * 25;
    std::ostringstream text;
    text.setf(std::ios::fixed);
    if (tenths % 10 == 0) {
        text.precision(0);
        text << (tenths / 10);
    } else {
        text.precision(1);
        text << (static_cast<double>(tenths) / 10.0);
    }
    text << "%";
    return text.str();
}

} // namespace

double snap_volume(double value) {
    if (!std::isfinite(value))
        return 0;
    value = std::max(0.0, std::min(kMax, value));
    value = round_to(value, kStep);
    if (value < 0)
        value = 0;
    if (value > kMax)
        value = kMax;
    return value;
}

double volume_fill(const Volume& volume) {
    if (!volume.valid || volume.muted)
        return 0;
    return std::max(0.0, std::min(1.0, snap_volume(volume.level) / kMax));
}

bool volume_overdrive(const Volume& volume) {
    return volume.valid && !volume.muted && snap_volume(volume.level) > 1.0;
}

std::string osd_label(const Volume& volume) {
    if (!volume.valid || volume.muted)
        return "MUTE";
    return format_step_percent(volume.level);
}

std::string menu_volume_caption(const Volume& volume) {
    if (!volume.valid || volume.muted || volume.level == 0)
        return "MUTE";
    return "VOL";
}

std::string menu_volume_percent(const Volume& volume) {
    if (!volume.valid)
        return "--%";
    if (volume.muted)
        return "0%";
    return format_step_percent(volume.level);
}

Volume parse_wpctl(const std::string& text) {
    Volume volume;
    auto   at = text.find("Volume:");
    if (at == std::string::npos)
        return volume;
    std::istringstream input(text.substr(at + 7));
    double             level = 0;
    if (!(input >> level))
        return volume;
    volume.level = std::max(0.0, level);
    volume.muted = text.find("[MUTED]") != std::string::npos;
    volume.valid = true;
    return volume;
}

bool operator==(const Volume& a, const Volume& b) {
    return a.valid == b.valid && a.muted == b.muted && std::abs(a.level - b.level) < 0.001;
}
