# use-libcxx.cmake
#
# CMake integration for using LLVM libc++ on Windows.
# Requires Clang (clang-cl or clang++).  Any other compiler is rejected.
#
# Automatically selects Debug/Release libraries from CMAKE_BUILD_TYPE / $<CONFIG>.
#
# ---- Providing libc++ -------------------------------------------------------
#
#   Option A — set LIBCXX_ROOT explicitly:
#     set(LIBCXX_ROOT "C:/libcxx-windows-x64")
#
#   Option B — from the release zip (auto-detected when this file is inside the
#              zip at  <root>/cmake/use-libcxx.cmake):
#     # nothing to set — LIBCXX_ROOT is inferred automatically.
#
# ---- Using libc++ -----------------------------------------------------------
#
#   # After project(), include this file, then either:
#   include(path/to/use-libcxx.cmake)
#   use_libcxx_globally()                   # applies to every target
#
#   # …or per target:
#   include(path/to/use-libcxx.cmake)
#   target_use_libcxx(my_target)            # applies to one target
#
# ---- Other variables ---------------------------------------------------------
#
#   LIBCXX_LINK_TYPE — "static" (default) or "shared"
#

cmake_minimum_required(VERSION 3.20)

# =============================================================================
# 1. Resolve LIBCXX_ROOT
# =============================================================================

# 1a. Explicit from the user — nothing to do.

# 1b. Auto-detect when this file sits inside a release zip.
if(NOT DEFINED LIBCXX_ROOT)
    get_filename_component(_use_libcxx_dir "${CMAKE_CURRENT_LIST_FILE}" DIRECTORY)
    get_filename_component(_use_libcxx_parent "${_use_libcxx_dir}/.." ABSOLUTE)
    if(EXISTS "${_use_libcxx_parent}/include/c++/v1/__config")
        set(LIBCXX_ROOT "${_use_libcxx_parent}")
    endif()
    unset(_use_libcxx_dir)
    unset(_use_libcxx_parent)
endif()

# 1c. Validate.
if(NOT DEFINED LIBCXX_ROOT OR NOT EXISTS "${LIBCXX_ROOT}/include/c++/v1/__config")
    message(FATAL_ERROR
        "[use-libcxx] LIBCXX_ROOT is not set or invalid.\n"
        "Set it to the directory containing include/ and lib/ from the release zip:\n"
        "  cmake -DLIBCXX_ROOT=path/to/libcxx-windows-x64 ...")
endif()

file(TO_CMAKE_PATH "${LIBCXX_ROOT}" LIBCXX_ROOT)

# =============================================================================
# 2. Defaults
# =============================================================================

if(NOT DEFINED LIBCXX_LINK_TYPE)
    set(LIBCXX_LINK_TYPE "static")
endif()

# =============================================================================
# 3. Require Clang
# =============================================================================

if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    message(FATAL_ERROR
        "[use-libcxx] libc++ requires Clang.  "
        "Current compiler: ${CMAKE_CXX_COMPILER_ID} (${CMAKE_CXX_COMPILER})\n"
        "Use one of:\n"
        "  cmake -DCMAKE_CXX_COMPILER=clang-cl ...   (MSVC-compatible, ships with Visual Studio)\n"
        "  cmake -DCMAKE_CXX_COMPILER=clang++ ...     (GNU-style)")
endif()

if(CMAKE_CXX_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC")
    set(_LIBCXX_COMPILER "clang-cl")
else()
    set(_LIBCXX_COMPILER "clang")
endif()

# Config-dependent subdirectory (works with single- and multi-config generators)
set(_LIBCXX_CFG "$<IF:$<CONFIG:Debug>,Debug,Release>")

# =============================================================================
# 4. Per-target function
# =============================================================================

function(target_use_libcxx target)
    if(_LIBCXX_COMPILER STREQUAL "clang-cl")
        target_compile_options(${target} PRIVATE
            "SHELL:/clang:-nostdinc++"
            "/I${LIBCXX_ROOT}/include/c++/v1")
    else()
        target_compile_options(${target} PRIVATE
            -nostdinc++
            "-I${LIBCXX_ROOT}/include/c++/v1")
    endif()

    target_compile_definitions(${target} PRIVATE
        _CRT_STDIO_ISO_WIDE_SPECIFIERS)

    target_link_directories(${target} PRIVATE
        "${LIBCXX_ROOT}/lib/${_LIBCXX_CFG}")

    target_link_libraries(${target} PRIVATE
        msvcprt$<$<CONFIG:Debug>:d>.lib)

    if(LIBCXX_LINK_TYPE STREQUAL "shared")
        target_link_libraries(${target} PRIVATE c++.lib)
    else()
        target_compile_definitions(${target} PRIVATE
            _LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS)
        target_link_libraries(${target} PRIVATE libc++.lib)
    endif()
endfunction()

# =============================================================================
# 5. Global convenience macro
# =============================================================================

macro(use_libcxx_globally)
    if(_LIBCXX_COMPILER STREQUAL "clang-cl")
        add_compile_options("SHELL:/clang:-nostdinc++"
                            "/I${LIBCXX_ROOT}/include/c++/v1")
    else()
        add_compile_options(-nostdinc++
                            "-I${LIBCXX_ROOT}/include/c++/v1")
    endif()

    add_compile_definitions(_CRT_STDIO_ISO_WIDE_SPECIFIERS)
    link_directories("${LIBCXX_ROOT}/lib/${_LIBCXX_CFG}")
    link_libraries(msvcprt$<$<CONFIG:Debug>:d>.lib)

    if(LIBCXX_LINK_TYPE STREQUAL "shared")
        link_libraries(c++.lib)
    else()
        add_compile_definitions(_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS)
        link_libraries(libc++.lib)
    endif()
endmacro()
