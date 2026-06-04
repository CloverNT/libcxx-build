#include <iostream>
#include <string>
#include <vector>
#include <algorithm>
#include <format>
#include <ranges>

int main() {
    std::vector<int> v{5, 3, 1, 4, 2};
    std::ranges::sort(v);

    std::string msg = std::format("libc++ works! sorted: [{}",  v[0]);
    for (size_t i = 1; i < v.size(); ++i)
        msg += std::format(", {}", v[i]);
    msg += "]";

    std::cout << msg << "\n";

#ifdef _LIBCPP_VERSION
    std::cout << "Using libc++ version: " << _LIBCPP_VERSION << "\n";
#else
    std::cout << "ERROR: NOT using libc++!\n";
    return 1;
#endif

    return 0;
}
