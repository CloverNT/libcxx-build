cmake_minimum_required(VERSION 3.20)
project(libcxx_test LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(${CMAKE_CURRENT_SOURCE_DIR}/../cmake/use-libcxx.cmake)

add_executable(test_static main.cpp)
target_use_libcxx(test_static)
