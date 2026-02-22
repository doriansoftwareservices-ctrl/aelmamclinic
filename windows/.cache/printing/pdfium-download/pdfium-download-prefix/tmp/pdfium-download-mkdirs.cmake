# Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
# file Copyright.txt or https://cmake.org/licensing for details.

cmake_minimum_required(VERSION 3.5)

# If CMAKE_DISABLE_SOURCE_CHANGES is set to true and the source directory is an
# existing directory in our source tree, calling file(MAKE_DIRECTORY) on it
# would cause a fatal error, even though it would be a no-op.
if(NOT EXISTS "C:/Users/zidan/AndroidStudioProjects/aelmamclinic/windows/.cache/printing/pdfium-src")
  file(MAKE_DIRECTORY "C:/Users/zidan/AndroidStudioProjects/aelmamclinic/windows/.cache/printing/pdfium-src")
endif()
file(MAKE_DIRECTORY
  "C:/Users/zidan/AndroidStudioProjects/aelmamclinic/windows/.cache/printing/pdfium-build"
  "C:/Users/zidan/AndroidStudioProjects/aelmamclinic/windows/.cache/printing/pdfium-download/pdfium-download-prefix"
  "C:/Users/zidan/AndroidStudioProjects/aelmamclinic/windows/.cache/printing/pdfium-download/pdfium-download-prefix/tmp"
  "C:/Users/zidan/AndroidStudioProjects/aelmamclinic/windows/.cache/printing/pdfium-download/pdfium-download-prefix/src/pdfium-download-stamp"
  "C:/Users/zidan/AndroidStudioProjects/aelmamclinic/windows/.cache/printing/pdfium-download/pdfium-download-prefix/src"
  "C:/Users/zidan/AndroidStudioProjects/aelmamclinic/windows/.cache/printing/pdfium-download/pdfium-download-prefix/src/pdfium-download-stamp"
)

set(configSubDirs Debug;Release;MinSizeRel;RelWithDebInfo)
foreach(subDir IN LISTS configSubDirs)
    file(MAKE_DIRECTORY "C:/Users/zidan/AndroidStudioProjects/aelmamclinic/windows/.cache/printing/pdfium-download/pdfium-download-prefix/src/pdfium-download-stamp/${subDir}")
endforeach()
if(cfgdir)
  file(MAKE_DIRECTORY "C:/Users/zidan/AndroidStudioProjects/aelmamclinic/windows/.cache/printing/pdfium-download/pdfium-download-prefix/src/pdfium-download-stamp${cfgdir}") # cfgdir has leading slash
endif()
