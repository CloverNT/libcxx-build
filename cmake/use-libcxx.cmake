# use-libcxx.cmake
#
# CMake integration for using LLVM libc++ on Windows.
# Requires Clang (clang-cl or clang++).  Any other compiler is rejected.
#
# Automatically selects Debug/Release libraries from CMAKE_BUILD_TYPE / $<CONFIG>.
#
# ---- Providing libc++ -------------------------------------------------------
#
#   Option A — local install (fastest, no network):
#     set(LIBCXX_ROOT "C:/libcxx-windows-x64")
#
#   Option B — auto-download from a GitHub Release:
#     set(LIBCXX_GITHUB_REPO "owner/repo")          # required
#     # set(LIBCXX_VERSION  "latest")                # or a tag, e.g. "v20.1.6"
#     # set(LIBCXX_DOWNLOAD_DIR "...")               # optional cache dir
#
#   Option C — from the release zip (auto-detected when this file is inside the
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
#   LIBCXX_LINK_TYPE      — "static" (default) or "shared"
#   LIBCXX_ABI_NAMESPACE  — inline namespace to match when auto-downloading
#                           (e.g. "__1", "__myns").  Default: "__1".
#

cmake_minimum_required(VERSION 3.20)

# =============================================================================
# 1. Auto-download helpers
# =============================================================================

function(_libcxx_query_github_release repo version abi_ns out_url out_tag)
    if("${version}" STREQUAL "" OR "${version}" STREQUAL "latest")
        set(_api "https://api.github.com/repos/${repo}/releases/latest")
    else()
        set(_api "https://api.github.com/repos/${repo}/releases/tags/${version}")
    endif()

    set(_json_file "${LIBCXX_DOWNLOAD_DIR}/_release_info.json")
    file(DOWNLOAD "${_api}" "${_json_file}"
        STATUS _st
        HTTPHEADER "Accept: application/vnd.github.v3+json"
    )
    list(GET _st 0 _code)
    if(NOT _code EQUAL 0)
        list(GET _st 1 _msg)
        message(FATAL_ERROR "[use-libcxx] GitHub API error (${_api}): ${_msg}")
    endif()

    file(READ "${_json_file}" _json)
    string(JSON _tag GET "${_json}" "tag_name")

    # Match asset:  libcxx-<ver>-windows-x64-<namespace>.zip
    string(JSON _n LENGTH "${_json}" "assets")
    if(_n EQUAL 0)
        message(FATAL_ERROR "[use-libcxx] Release ${_tag} has no assets")
    endif()
    math(EXPR _last "${_n} - 1")
    set(_found FALSE)
    foreach(_i RANGE 0 ${_last})
        string(JSON _name GET "${_json}" "assets" ${_i} "name")
        if(_name MATCHES "windows-x64-${abi_ns}\\.zip$")
            string(JSON _dl GET "${_json}" "assets" ${_i} "browser_download_url")
            set(${out_url} "${_dl}" PARENT_SCOPE)
            set(${out_tag} "${_tag}" PARENT_SCOPE)
            set(_found TRUE)
            break()
        endif()
    endforeach()
    if(NOT _found)
        message(FATAL_ERROR
            "[use-libcxx] No asset matching namespace '${abi_ns}' in release ${_tag}.\n"
            "Available assets can be viewed at:\n"
            "  https://github.com/${repo}/releases/tag/${_tag}")
    endif()
endfunction()

macro(_libcxx_auto_download)
    if(NOT DEFINED LIBCXX_DOWNLOAD_DIR)
        set(LIBCXX_DOWNLOAD_DIR "${CMAKE_BINARY_DIR}/_deps/libcxx")
    endif()
    if(NOT DEFINED LIBCXX_ABI_NAMESPACE)
        set(LIBCXX_ABI_NAMESPACE "__1")
    endif()
    file(MAKE_DIRECTORY "${LIBCXX_DOWNLOAD_DIR}")

    _libcxx_query_github_release(
        "${LIBCXX_GITHUB_REPO}" "${LIBCXX_VERSION}"
        "${LIBCXX_ABI_NAMESPACE}" _dl_url _dl_tag)

    message(STATUS "[use-libcxx] Resolved release: ${_dl_tag}  namespace: ${LIBCXX_ABI_NAMESPACE}")
    set(_cache "${LIBCXX_DOWNLOAD_DIR}/${_dl_tag}-${LIBCXX_ABI_NAMESPACE}")

    if(NOT EXISTS "${_cache}/include/c++/v1/__config")
        message(STATUS "[use-libcxx] Downloading ${_dl_url} ...")
        set(_zip "${LIBCXX_DOWNLOAD_DIR}/_libcxx_${_dl_tag}.zip")
        file(DOWNLOAD "${_dl_url}" "${_zip}" STATUS _st SHOW_PROGRESS)
        list(GET _st 0 _code)
        if(NOT _code EQUAL 0)
            list(GET _st 1 _msg)
            file(REMOVE "${_zip}")
            message(FATAL_ERROR "[use-libcxx] Download failed: ${_msg}")
        endif()
        file(ARCHIVE_EXTRACT INPUT "${_zip}" DESTINATION "${_cache}")
        file(REMOVE "${_zip}")
    else()
        message(STATUS "[use-libcxx] Using cached: ${_cache}")
    endif()

    set(LIBCXX_ROOT "${_cache}")
endmacro()

# =============================================================================
# 2. Resolve LIBCXX_ROOT
# =============================================================================

# 2a. Explicit from the user — nothing to do.

# 2b. Auto-detect when this file sits inside a release zip.
if(NOT DEFINED LIBCXX_ROOT)
    get_filename_component(_use_libcxx_dir "${CMAKE_CURRENT_LIST_FILE}" DIRECTORY)
    get_filename_component(_use_libcxx_parent "${_use_libcxx_dir}/.." ABSOLUTE)
    if(EXISTS "${_use_libcxx_parent}/include/c++/v1/__config")
        set(LIBCXX_ROOT "${_use_libcxx_parent}")
    endif()
    unset(_use_libcxx_dir)
    unset(_use_libcxx_parent)
endif()

# 2c. Auto-download from GitHub.
if((NOT DEFINED LIBCXX_ROOT OR NOT EXISTS "${LIBCXX_ROOT}/include/c++/v1/__config")
   AND DEFINED LIBCXX_GITHUB_REPO)
    _libcxx_auto_download()
endif()

# 2d. Validate.
if(NOT DEFINED LIBCXX_ROOT OR NOT EXISTS "${LIBCXX_ROOT}/include/c++/v1/__config")
    message(FATAL_ERROR
        "LIBCXX_ROOT is not set or invalid.\n"
        "Either:\n"
        "  -DLIBCXX_ROOT=path/to/libcxx-windows-x64\n"
        "  -DLIBCXX_GITHUB_REPO=owner/repo          (auto-download)\n"
        "  -DLIBCXX_GITHUB_REPO=owner/repo -DLIBCXX_VERSION=v20.1.6")
endif()

file(TO_CMAKE_PATH "${LIBCXX_ROOT}" LIBCXX_ROOT)
message(STATUS "[use-libcxx] LIBCXX_ROOT = ${LIBCXX_ROOT}")

# =============================================================================
# 3. Defaults
# =============================================================================

if(NOT DEFINED LIBCXX_LINK_TYPE)
    set(LIBCXX_LINK_TYPE "static")
endif()

# =============================================================================
# 4. Require Clang
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
message(STATUS "[use-libcxx] Compiler mode: ${_LIBCXX_COMPILER}")

# Config-dependent subdirectory (works with single- and multi-config generators)
set(_LIBCXX_CFG "$<IF:$<CONFIG:Debug>,Debug,Release>")

# =============================================================================
# 5. Per-target function
# =============================================================================

function(target_use_libcxx target)
    # ---- headers + nostdinc++ ----
    if(_LIBCXX_COMPILER STREQUAL "clang-cl")
        target_compile_options(${target} PRIVATE
            "SHELL:/clang:-nostdinc++"
            "/I${LIBCXX_ROOT}/include/c++/v1")
    else()  # clang (GNU-style)
        target_compile_options(${target} PRIVATE
            -nostdinc++
            "-I${LIBCXX_ROOT}/include/c++/v1")
    endif()

    # ---- compile definitions ----
    target_compile_definitions(${target} PRIVATE
        _CRT_STDIO_ISO_WIDE_SPECIFIERS)

    # ---- link directories (config-aware) ----
    target_link_directories(${target} PRIVATE
        "${LIBCXX_ROOT}/lib/${_LIBCXX_CFG}")

    # MSVC C++ runtime helpers (exception_ptr etc.) are not auto-linked when
    # MSVC STL headers are absent.  msvcprtd.lib for Debug, msvcprt.lib otherwise.
    target_link_libraries(${target} PRIVATE
        msvcprt$<$<CONFIG:Debug>:d>.lib)

    # ---- static vs shared ----
    if(LIBCXX_LINK_TYPE STREQUAL "shared")
        target_link_libraries(${target} PRIVATE c++.lib)
    else()
        target_compile_definitions(${target} PRIVATE
            _LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS)
        target_link_libraries(${target} PRIVATE libc++.lib)
    endif()
endfunction()

# =============================================================================
# 6. Global convenience macro
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
