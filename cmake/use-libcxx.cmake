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
#     set(LibCxxRoot "C:/libcxx-windows-x64")
#
#   Option B — auto-download from a GitHub Release:
#     set(LibCxxGitHubRepo "owner/repo")          # required
#     # set(LibCxxVersion  "latest")               # or a tag, e.g. "v20.1.6"
#     # set(LibCxxDownloadDir "...")               # optional cache dir
#
#   Option C — from the release zip (auto-detected when this file is inside the
#              zip at  <root>/cmake/use-libcxx.cmake):
#     # nothing to set — LibCxxRoot is inferred automatically.
#
# ---- Using libc++ -----------------------------------------------------------
#
#   # After project(), include this file, then either:
#   include(path/to/use-libcxx.cmake)
#   UseLibCxxGlobally()                   # applies to every target
#
#   # …or per target:
#   include(path/to/use-libcxx.cmake)
#   TargetUseLibCxx(my_target)            # applies to one target
#
# ---- Other variables ---------------------------------------------------------
#
#   LibCxxLinkType      — "static" (default) or "shared"
#   LibCxxAbiNamespace  — inline namespace to match when auto-downloading
#                         (e.g. "__1", "__myns").  Default: "__1".
#

cmake_minimum_required(VERSION 3.20)

# =============================================================================
# 1. Auto-download helpers
# =============================================================================

function(_LibCxx_QueryGitHubRelease repo version abi_ns out_url out_tag)
    if("${version}" STREQUAL "" OR "${version}" STREQUAL "latest")
        set(_api "https://api.github.com/repos/${repo}/releases/latest")
    else()
        set(_api "https://api.github.com/repos/${repo}/releases/tags/${version}")
    endif()

    set(_json_file "${LibCxxDownloadDir}/_release_info.json")
    file(DOWNLOAD "${_api}" "${_json_file}"
        STATUS _st
        HTTPHEADER "Accept: application/vnd.github.v3+json"
    )
    list(GET _st 0 _code)
    if(NOT _code EQUAL 0)
        list(GET _st 1 _msg)
        message(FATAL_ERROR "[LibCxx] GitHub API error (${_api}): ${_msg}")
    endif()

    file(READ "${_json_file}" _json)
    string(JSON _tag GET "${_json}" "tag_name")

    string(JSON _n LENGTH "${_json}" "assets")
    if(_n EQUAL 0)
        message(FATAL_ERROR "[LibCxx] Release ${_tag} has no assets")
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
            "[LibCxx] No asset matching namespace '${abi_ns}' in release ${_tag}.\n"
            "Available assets can be viewed at:\n"
            "  https://github.com/${repo}/releases/tag/${_tag}")
    endif()
endfunction()

macro(_LibCxx_AutoDownload)
    if(NOT DEFINED LibCxxDownloadDir)
        set(LibCxxDownloadDir "${CMAKE_BINARY_DIR}/_deps/libcxx")
    endif()
    if(NOT DEFINED LibCxxAbiNamespace)
        set(LibCxxAbiNamespace "__1")
    endif()
    file(MAKE_DIRECTORY "${LibCxxDownloadDir}")

    _LibCxx_QueryGitHubRelease(
        "${LibCxxGitHubRepo}" "${LibCxxVersion}"
        "${LibCxxAbiNamespace}" _dl_url _dl_tag)

    set(_cache "${LibCxxDownloadDir}/${_dl_tag}-${LibCxxAbiNamespace}")

    if(NOT EXISTS "${_cache}/include/c++/v1/__config")
        set(_zip "${LibCxxDownloadDir}/_libcxx_${_dl_tag}.zip")
        file(DOWNLOAD "${_dl_url}" "${_zip}" STATUS _st SHOW_PROGRESS)
        list(GET _st 0 _code)
        if(NOT _code EQUAL 0)
            list(GET _st 1 _msg)
            file(REMOVE "${_zip}")
            message(FATAL_ERROR "[LibCxx] Download failed: ${_msg}")
        endif()
        file(ARCHIVE_EXTRACT INPUT "${_zip}" DESTINATION "${_cache}")
        file(REMOVE "${_zip}")
    endif()

    set(LibCxxRoot "${_cache}")
endmacro()

# =============================================================================
# 2. Resolve LibCxxRoot
# =============================================================================

if(NOT DEFINED LibCxxRoot)
    get_filename_component(_use_libcxx_dir "${CMAKE_CURRENT_LIST_FILE}" DIRECTORY)
    get_filename_component(_use_libcxx_parent "${_use_libcxx_dir}/.." ABSOLUTE)
    if(EXISTS "${_use_libcxx_parent}/include/c++/v1/__config")
        set(LibCxxRoot "${_use_libcxx_parent}")
    endif()
    unset(_use_libcxx_dir)
    unset(_use_libcxx_parent)
endif()

if((NOT DEFINED LibCxxRoot OR NOT EXISTS "${LibCxxRoot}/include/c++/v1/__config")
   AND DEFINED LibCxxGitHubRepo)
    _LibCxx_AutoDownload()
endif()

if(NOT DEFINED LibCxxRoot OR NOT EXISTS "${LibCxxRoot}/include/c++/v1/__config")
    message(FATAL_ERROR
        "[LibCxx] LibCxxRoot is not set or invalid.\n"
        "Either:\n"
        "  -DLibCxxRoot=path/to/libcxx-windows-x64\n"
        "  -DLibCxxGitHubRepo=owner/repo          (auto-download)\n"
        "  -DLibCxxGitHubRepo=owner/repo -DLibCxxVersion=v20.1.6")
endif()

file(TO_CMAKE_PATH "${LibCxxRoot}" LibCxxRoot)

# =============================================================================
# 3. Defaults
# =============================================================================

if(NOT DEFINED LibCxxLinkType)
    set(LibCxxLinkType "static")
endif()

# =============================================================================
# 4. Require Clang
# =============================================================================

if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    message(FATAL_ERROR
        "[LibCxx] libc++ requires Clang.  "
        "Current compiler: ${CMAKE_CXX_COMPILER_ID} (${CMAKE_CXX_COMPILER})\n"
        "Use one of:\n"
        "  cmake -DCMAKE_CXX_COMPILER=clang-cl ...\n"
        "  cmake -DCMAKE_CXX_COMPILER=clang++ ...")
endif()

if(CMAKE_CXX_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC")
    set(_LIBCXX_COMPILER "clang-cl")
else()
    set(_LIBCXX_COMPILER "clang")
endif()

set(_LIBCXX_CFG "$<IF:$<CONFIG:Debug>,Debug,Release>")

# =============================================================================
# 5. Per-target function
# =============================================================================

function(TargetUseLibCxx target)
    if(_LIBCXX_COMPILER STREQUAL "clang-cl")
        target_compile_options(${target} PRIVATE
            "SHELL:/clang:-nostdinc++"
            "/I${LibCxxRoot}/include/c++/v1")
    else()
        target_compile_options(${target} PRIVATE
            -nostdinc++
            "-I${LibCxxRoot}/include/c++/v1")
    endif()

    target_compile_definitions(${target} PRIVATE
        _CRT_STDIO_ISO_WIDE_SPECIFIERS)

    target_link_directories(${target} PRIVATE
        "${LibCxxRoot}/lib/${_LIBCXX_CFG}")

    target_link_libraries(${target} PRIVATE
        msvcprt$<$<CONFIG:Debug>:d>.lib)

    if(LibCxxLinkType STREQUAL "shared")
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

macro(UseLibCxxGlobally)
    if(_LIBCXX_COMPILER STREQUAL "clang-cl")
        add_compile_options("SHELL:/clang:-nostdinc++"
                            "/I${LibCxxRoot}/include/c++/v1")
    else()
        add_compile_options(-nostdinc++
                            "-I${LibCxxRoot}/include/c++/v1")
    endif()

    add_compile_definitions(_CRT_STDIO_ISO_WIDE_SPECIFIERS)
    link_directories("${LibCxxRoot}/lib/${_LIBCXX_CFG}")
    link_libraries(msvcprt$<$<CONFIG:Debug>:d>.lib)

    if(LibCxxLinkType STREQUAL "shared")
        link_libraries(c++.lib)
    else()
        add_compile_definitions(_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS)
        link_libraries(libc++.lib)
    endif()
endmacro()
