# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(aelmamclinic LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "aelmamclinic")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /MP)
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Cache heavy native SDKs outside the build tree so `flutter clean`
# does not force large downloads on every rebuild.
set(WINDOWS_NATIVE_CACHE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.cache")
file(MAKE_DIRECTORY "${WINDOWS_NATIVE_CACHE_ROOT}")

set(_firebase_plugin_cmake
    "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/firebase_core/windows/CMakeLists.txt")
if(EXISTS "${_firebase_plugin_cmake}")
  file(READ "${_firebase_plugin_cmake}" _firebase_plugin_contents)
  string(REGEX MATCH "set\\(FIREBASE_SDK_VERSION \"([^\"]+)\"\\)"
         _firebase_version_match "${_firebase_plugin_contents}")
  set(_firebase_sdk_version "${CMAKE_MATCH_1}")
  if(_firebase_sdk_version)
    set(_firebase_cache_root
        "${WINDOWS_NATIVE_CACHE_ROOT}/firebase_cpp_sdk/${_firebase_sdk_version}")
    set(_firebase_zip
        "${_firebase_cache_root}/firebase_cpp_sdk_windows_${_firebase_sdk_version}.zip")
    set(_firebase_sdk_dir "${_firebase_cache_root}/firebase_cpp_sdk_windows")
    set(_firebase_version_header "${_firebase_sdk_dir}/include/firebase/version.h")
    set(_firebase_cache_ready FALSE)
    if(EXISTS "${_firebase_version_header}")
      set(_firebase_cache_ready TRUE)
      message(STATUS "Using cached Firebase C++ SDK ${_firebase_sdk_version}")
    else()
      file(MAKE_DIRECTORY "${_firebase_cache_root}")
      if(NOT EXISTS "${_firebase_zip}")
        set(_firebase_url
            "https://dl.google.com/firebase/sdk/cpp/firebase_cpp_sdk_windows_${_firebase_sdk_version}.zip")
        message(STATUS "Caching Firebase C++ SDK ${_firebase_sdk_version}")
        file(DOWNLOAD "${_firebase_url}" "${_firebase_zip}" SHOW_PROGRESS
             STATUS _firebase_download_status LOG _firebase_download_log)
        list(GET _firebase_download_status 0 _firebase_download_code)
        if(NOT _firebase_download_code EQUAL 0)
          file(REMOVE "${_firebase_zip}")
          message(FATAL_ERROR
                  "Failed to download Firebase C++ SDK: ${_firebase_download_log}")
        endif()
      endif()
      if(EXISTS "${_firebase_sdk_dir}")
        file(REMOVE_RECURSE "${_firebase_sdk_dir}")
      endif()
      message(STATUS "Extracting Firebase C++ SDK ${_firebase_sdk_version}")
      file(ARCHIVE_EXTRACT INPUT "${_firebase_zip}"
           DESTINATION "${_firebase_cache_root}")
      if(EXISTS "${_firebase_version_header}")
        set(_firebase_cache_ready TRUE)
      endif()
    endif()
    if(_firebase_cache_ready)
      set(ENV{FIREBASE_CPP_SDK_DIR} "${_firebase_sdk_dir}")
    endif()
  endif()
endif()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
# Always install into the build bundle dir so elevated permissions aren't needed.
set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
