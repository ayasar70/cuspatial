# =============================================================================
# Copyright (c) 2022-2023, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied. See the License for the specific language governing permissions and limitations under
# the License.
# =============================================================================

cmake_minimum_required(VERSION 3.26.4 FATAL_ERROR)

set(cuspatial_version 23.08.00)

include(../../fetch_rapids.cmake)
include(rapids-cuda)
rapids_cuda_init_architectures(cuspatial-python)

project(
  cuspatial-python
  VERSION ${cuspatial_version}
  LANGUAGES # TODO: Building Python extension modules via the python_extension_module requires the C
            # language to be enabled here. The test project that is built in scikit-build to verify
            # various linking options for the python library is hardcoded to build with C, so until
            # that is fixed we need to keep C.
            C CXX CUDA)

option(FIND_CUSPATIAL_CPP "Search for existing cuspatial C++ installations before defaulting to local files"
       OFF)

option(CUSPATIAL_BUILD_WHEELS "Whether this build is generating a Python wheel." OFF)

# If the user requested it we attempt to find cuspatial.
if(FIND_CUSPATIAL_CPP)
  find_package(cuspatial ${cuspatial_version})
else()
  set(cuspatial_FOUND OFF)
endif()

if(NOT cuspatial_FOUND)
  set(BUILD_TESTS OFF)
  set(BUILD_BENCHMARKS OFF)
  set(_exclude_from_all "")
  if(CUSPATIAL_BUILD_WHEELS)

    # Statically link cudart if building wheels
    set(CUDA_STATIC_RUNTIME ON)
    set(CUSPATIAL_USE_CUDF_STATIC ON)
    set(CUSPATIAL_EXCLUDE_CUDF_FROM_ALL ON)

    # Always build wheels against the pyarrow libarrow.
    set(USE_LIBARROW_FROM_PYARROW ON)

    # Need to set this so all the nvcomp targets are global, not only nvcomp::nvcomp
    # https://cmake.org/cmake/help/latest/variable/CMAKE_FIND_PACKAGE_TARGETS_GLOBAL.html#variable:CMAKE_FIND_PACKAGE_TARGETS_GLOBAL
    set(CMAKE_FIND_PACKAGE_TARGETS_GLOBAL ON)

    # Don't install the cuSpatial C++ targets into wheels
    set(_exclude_from_all EXCLUDE_FROM_ALL)
  endif()

  add_subdirectory(../../cpp cuspatial-cpp ${_exclude_from_all})

  set(cython_lib_dir cuspatial)

  if(CUSPATIAL_BUILD_WHEELS)
    include(cmake/Modules/WheelHelpers.cmake)
    get_target_property(_nvcomp_link_libs nvcomp::nvcomp INTERFACE_LINK_LIBRARIES)
    # Ensure all the shared objects we need at runtime are in the wheel
    add_target_libs_to_wheel(LIB_DIR ${cython_lib_dir} TARGETS arrow_shared nvcomp::nvcomp ${_nvcomp_link_libs})
  endif()

  # Since there are multiple subpackages of cuspatial._lib that require access to libcuspatial, we place the
  # library in the cuspatial directory as a single source of truth and modify the other rpaths
  # appropriately.
  install(TARGETS cuspatial DESTINATION ${cython_lib_dir})
endif()

include(rapids-cython)
rapids_cython_init()

add_subdirectory(cuspatial/_lib)

if(DEFINED cython_lib_dir)
  rapids_cython_add_rpath_entries(TARGET cuspatial PATHS "${cython_lib_dir}")
endif()
