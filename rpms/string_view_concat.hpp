#pragma once

#include <string>
#include <string_view>

// Rock GCC 14 libstdc++ has no operator+(string, string_view) in C++23.
// Compile flag only. This header is not installed.
namespace std {
inline string operator+(string lhs, string_view rhs) {
    lhs.append(rhs.data(), rhs.size());
    return lhs;
}

inline string operator+(string_view lhs, const string& rhs) {
    string out(lhs);
    out.append(rhs);
    return out;
}
} // namespace std
