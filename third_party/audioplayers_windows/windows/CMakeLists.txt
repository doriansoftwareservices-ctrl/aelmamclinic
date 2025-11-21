cmake_minimum_required(VERSION 3.15)
set(PROJECT_NAME "audioplayers_windows")
set(WIL_VERSION "1.0.210803.1")
project(${PROJECT_NAME} LANGUAGES CXX)
include(FetchContent)

set(WIL_PACKAGE_DIR "${CMAKE_BINARY_DIR}/packages/Microsoft.Windows.ImplementationLibrary")
set(WIL_PACKAGE_TARGET "${WIL_PACKAGE_DIR}/build/native/Microsoft.Windows.ImplementationLibrary.targets")
set(WIL_PACKAGE_READY FALSE)

set(_wil_candidate_paths "")
if(DEFINED ENV{WIL_PACKAGE_ROOT})
  list(APPEND _wil_candidate_paths "$ENV{WIL_PACKAGE_ROOT}")
endif()
if(DEFINED ENV{WIL_NUGET_CACHE})
  list(APPEND _wil_candidate_paths "$ENV{WIL_NUGET_CACHE}")
  list(APPEND _wil_candidate_paths "$ENV{WIL_NUGET_CACHE}/microsoft.windows.implementationlibrary/${WIL_VERSION}")
  list(APPEND _wil_candidate_paths "$ENV{WIL_NUGET_CACHE}/Microsoft.Windows.ImplementationLibrary/${WIL_VERSION}")
endif()
if(DEFINED ENV{NUGET_PACKAGES})
  list(APPEND _wil_candidate_paths "$ENV{NUGET_PACKAGES}/microsoft.windows.implementationlibrary/${WIL_VERSION}")
endif()
if(DEFINED ENV{USERPROFILE})
  list(APPEND _wil_candidate_paths "$ENV{USERPROFILE}/.nuget/packages/microsoft.windows.implementationlibrary/${WIL_VERSION}")
endif()

foreach(candidate IN LISTS _wil_candidate_paths)
  if(candidate STREQUAL "")
    continue()
  endif()
  file(TO_CMAKE_PATH "${candidate}" candidate_path)
  if(EXISTS "${candidate_path}/build/native/Microsoft.Windows.ImplementationLibrary.targets")
    set(WIL_OFFLINE_SOURCE "${candidate_path}")
    break()
  endif()
endforeach()

if(DEFINED WIL_OFFLINE_SOURCE)
  message(STATUS "Using cached Microsoft.Windows.ImplementationLibrary from ${WIL_OFFLINE_SOURCE}")
  file(MAKE_DIRECTORY "${WIL_PACKAGE_DIR}")
  file(COPY "${WIL_OFFLINE_SOURCE}/build" DESTINATION "${WIL_PACKAGE_DIR}")
  file(COPY "${WIL_OFFLINE_SOURCE}/include" DESTINATION "${WIL_PACKAGE_DIR}")
  set(WIL_PACKAGE_READY TRUE)
endif()

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

if (NOT WIL_PACKAGE_READY)
  FetchContent_Declare(nuget
    URL "https://dist.nuget.org/win-x86-commandline/v6.5.0/nuget.exe"
    URL_HASH SHA256=d5fce5185de92b7356ea9264b997a620e35c6f6c3c061e471e0dc3a84b3d74fd
    DOWNLOAD_NO_EXTRACT true
  )

  find_program(NUGET nuget)
  if (NOT NUGET)
      message(STATUS "Nuget.exe not found, trying to download or use cached version.")
      FetchContent_MakeAvailable(nuget)
      set(NUGET ${nuget_SOURCE_DIR}/nuget.exe)
  endif()

  execute_process(COMMAND
      ${NUGET} install Microsoft.Windows.ImplementationLibrary -Version ${WIL_VERSION} -ExcludeVersion -OutputDirectory ${CMAKE_BINARY_DIR}/packages
      WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
      RESULT_VARIABLE ret)
  if (ret EQUAL 0)
      set(WIL_PACKAGE_READY TRUE)
  else()
      message(FATAL_ERROR "Failed to install NuGet package Microsoft.Windows.ImplementationLibrary.${WIL_VERSION}. Provide an offline copy via the WIL_PACKAGE_ROOT/WIL_NUGET_CACHE env variables or ensure it exists under %USERPROFILE%/.nuget/packages.")
  endif()
endif()

add_library(${PLUGIN_NAME} SHARED
  "audioplayers_windows_plugin.cpp"
  "audio_player.h"
  "audio_player.cpp"
  "audioplayers_helpers.h"
  "event_stream_handler.h"
  "MediaEngineExtension.h"
  "MediaEngineExtension.cpp"
  "MediaFoundationHelpers.h"
  "MediaEngineWrapper.h"
  "MediaEngineWrapper.cpp"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)

target_link_libraries(${PLUGIN_NAME} PRIVATE ${CMAKE_BINARY_DIR}/packages/Microsoft.Windows.ImplementationLibrary/build/native/Microsoft.Windows.ImplementationLibrary.targets)
target_link_libraries(${PLUGIN_NAME} PRIVATE Mfplat windowsapp)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
target_link_libraries(${PLUGIN_NAME} PRIVATE shlwapi)

# List of absolute paths to libraries that should be bundled with the plugin
set(audioplayers_windows_bundled_libraries
  ""
  PARENT_SCOPE
)
