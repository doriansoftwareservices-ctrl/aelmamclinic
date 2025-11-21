cmake_minimum_required(VERSION 3.15)
set(PROJECT_NAME "permission_handler_windows")
set(CPPWINRT_VERSION "2.0.210806.1")
project(${PROJECT_NAME} LANGUAGES CXX)
include(FetchContent)

set(CPPWINRT_PACKAGE_NAME "Microsoft.Windows.CppWinRT.${CPPWINRT_VERSION}")
set(CPPWINRT_PACKAGE_ROOT "${CMAKE_BINARY_DIR}/packages")
set(CPPWINRT_PACKAGE_DIR "${CPPWINRT_PACKAGE_ROOT}/${CPPWINRT_PACKAGE_NAME}")
set(CPPWINRT_EXE "${CPPWINRT_PACKAGE_DIR}/bin/cppwinrt.exe")
set(CPPWINRT_PACKAGE_READY FALSE)

set(_cppwinrt_candidate_paths "")
if(DEFINED ENV{CPPWINRT_PACKAGE_ROOT})
  list(APPEND _cppwinrt_candidate_paths "$ENV{CPPWINRT_PACKAGE_ROOT}")
endif()
if(DEFINED ENV{CPPWINRT_NUGET_CACHE})
  list(APPEND _cppwinrt_candidate_paths "$ENV{CPPWINRT_NUGET_CACHE}")
  list(APPEND _cppwinrt_candidate_paths "$ENV{CPPWINRT_NUGET_CACHE}/microsoft.windows.cppwinrt/${CPPWINRT_VERSION}")
endif()
if(DEFINED ENV{NUGET_PACKAGES})
  list(APPEND _cppwinrt_candidate_paths "$ENV{NUGET_PACKAGES}/microsoft.windows.cppwinrt/${CPPWINRT_VERSION}")
endif()
if(DEFINED ENV{USERPROFILE})
  list(APPEND _cppwinrt_candidate_paths "$ENV{USERPROFILE}/.nuget/packages/microsoft.windows.cppwinrt/${CPPWINRT_VERSION}")
endif()

foreach(candidate IN LISTS _cppwinrt_candidate_paths)
  if(candidate STREQUAL "")
    continue()
  endif()
  file(TO_CMAKE_PATH "${candidate}" candidate_path)
  if(EXISTS "${candidate_path}/bin/cppwinrt.exe")
    set(CPPWINRT_OFFLINE_SOURCE "${candidate_path}")
    break()
  endif()
endforeach()

if(DEFINED CPPWINRT_OFFLINE_SOURCE)
  message(STATUS "Using cached Microsoft.Windows.CppWinRT from ${CPPWINRT_OFFLINE_SOURCE}")
  file(MAKE_DIRECTORY "${CPPWINRT_PACKAGE_DIR}")
  if (NOT EXISTS "${CPPWINRT_EXE}")
    file(COPY "${CPPWINRT_OFFLINE_SOURCE}/" DESTINATION "${CPPWINRT_PACKAGE_DIR}")
  endif()
  set(CPPWINRT_PACKAGE_READY TRUE)
endif()

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

if (NOT CPPWINRT_PACKAGE_READY)
  FetchContent_Declare(nuget
    URL "https://dist.nuget.org/win-x86-commandline/v6.0.0/nuget.exe"
    URL_HASH SHA256=04eb6c4fe4213907e2773e1be1bbbd730e9a655a3c9c58387ce8d4a714a5b9e1
    DOWNLOAD_NO_EXTRACT true
  )

  find_program(NUGET nuget)
  if (NOT NUGET)
      message("Nuget.exe not found, trying to download or use cached version.")
      FetchContent_MakeAvailable(nuget)
      set(NUGET ${nuget_SOURCE_DIR}/nuget.exe)
  endif()

  execute_process(COMMAND
      ${NUGET} install Microsoft.Windows.CppWinRT -Version ${CPPWINRT_VERSION} -OutputDirectory ${CPPWINRT_PACKAGE_ROOT}
      WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
      RESULT_VARIABLE ret)
  if (ret EQUAL 0)
      set(CPPWINRT_PACKAGE_READY TRUE)
  else()
      message(FATAL_ERROR "Failed to install NuGet package Microsoft.Windows.CppWinRT.${CPPWINRT_VERSION}. Provide an offline copy via CPPWINRT_PACKAGE_ROOT/CPPWINRT_NUGET_CACHE or place it under %USERPROFILE%/.nuget/packages.")
  endif()
endif()

set(CPPWINRT ${CPPWINRT_EXE})
execute_process(COMMAND
    ${CPPWINRT} -input sdk -output include
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
    RESULT_VARIABLE ret)
if (NOT ret EQUAL 0)
    message(FATAL_ERROR "Failed to run cppwinrt.exe")
endif()

include_directories(BEFORE SYSTEM ${CMAKE_BINARY_DIR}/include)

add_library(${PLUGIN_NAME} SHARED
  "include/permission_handler_windows/permission_handler_windows_plugin.h"
  "permission_handler_windows_plugin.cpp"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_20)
target_compile_options(${PLUGIN_NAME} PRIVATE /await)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# List of absolute paths to libraries that should be bundled with the plugin
set(permission_handler_windows_bundled_libraries
  ""
  PARENT_SCOPE
)
