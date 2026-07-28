cmake_minimum_required(VERSION 3.18)
project(fft_test LANGUAGES Fortran)

# ---------------------------------------------------------------------------
# Backend selection: FFTW, MKL, or AOCL.
#
# All three are exercised through the exact same source code because they
# each provide (or can provide) a double-precision, FFTW3-ABI-compatible
# Fortran interface (fftw3.f03, "fftw_*" symbols):
#   - FFTW      : upstream FFTW3.
#   - MKL       : Intel MKL's built-in FFTW3 wrappers
#                 ($MKLROOT/include/fftw, libmkl_rt).
#   - AOCL      : AMD's amd-fftw (AOCL-FFT's FFTW3-compatible build), which
#                 is a drop-in libfftw3.so built from the FFTW3 sources with
#                 AMD Zen tuning. Point AOCL_ROOT at that install.
# ---------------------------------------------------------------------------
set(FFT_BACKEND "FFTW" CACHE STRING "FFT backend to benchmark: FFTW, MKL, or AOCL")
set_property(CACHE FFT_BACKEND PROPERTY STRINGS FFTW MKL AOCL)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

if(CMAKE_Fortran_COMPILER_ID MATCHES "GNU")
  set(CMAKE_Fortran_FLAGS_RELEASE "-O3 -march=native -funroll-loops")
elseif(CMAKE_Fortran_COMPILER_ID MATCHES "Intel")
  set(CMAKE_Fortran_FLAGS_RELEASE "-O3 -xHost")
endif()

if(FFT_BACKEND STREQUAL "FFTW")
  # 1) Try the FFTW3-provided CMake config (Homebrew, many Linux installs).
  find_package(FFTW3 CONFIG QUIET)
  if(FFTW3_FOUND)
    set(FFT_INCLUDE_DIRS ${FFTW3_INCLUDE_DIRS})
    find_library(FFT_LIBRARIES NAMES fftw3 HINTS ${FFTW3_LIBRARY_DIRS})
  else()
    # 2) Try pkg-config.
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
      pkg_check_modules(PC_FFTW3 QUIET fftw3)
    endif()
    if(PC_FFTW3_FOUND)
      set(FFT_INCLUDE_DIRS ${PC_FFTW3_INCLUDE_DIRS})
      set(FFT_LIBRARIES ${PC_FFTW3_LIBRARIES})
      link_directories(${PC_FFTW3_LIBRARY_DIRS})
    else()
      # 3) Manual search, honoring FFTW_ROOT / FFTW3_ROOT env vars.
      find_path(FFT_INCLUDE_DIRS fftw3.f03
        HINTS ENV FFTW_ROOT ENV FFTW3_ROOT /opt/homebrew/opt/fftw /usr/local/opt/fftw
        PATH_SUFFIXES include)
      find_library(FFT_LIBRARIES NAMES fftw3
        HINTS ENV FFTW_ROOT ENV FFTW3_ROOT /opt/homebrew/opt/fftw /usr/local/opt/fftw
        PATH_SUFFIXES lib lib64)
    endif()
  endif()

  if(NOT FFT_INCLUDE_DIRS OR NOT FFT_LIBRARIES)
    message(FATAL_ERROR "FFTW3 not found. Install it (e.g. 'brew install fftw' or "
                         "'apt install libfftw3-dev') or point FFTW_ROOT/FFTW3_ROOT at it.")
  endif()
  set(FFT_BACKEND_NAME "FFTW3")

elseif(FFT_BACKEND STREQUAL "MKL")
  if(NOT DEFINED ENV{MKLROOT})
    message(FATAL_ERROR "MKLROOT is not set. Source Intel MKL's env/vars.sh (or setvars.sh) first.")
  endif()
  set(MKLROOT_DIR $ENV{MKLROOT})

  find_path(FFT_INCLUDE_DIRS fftw3.f03
    HINTS ${MKLROOT_DIR}/include/fftw ${MKLROOT_DIR}/include)
  find_library(MKL_RT_LIBRARY NAMES mkl_rt
    HINTS ${MKLROOT_DIR}/lib ${MKLROOT_DIR}/lib/intel64)

  if(NOT FFT_INCLUDE_DIRS OR NOT MKL_RT_LIBRARY)
    message(FATAL_ERROR "Could not find MKL's fftw3.f03 / libmkl_rt under MKLROOT=${MKLROOT_DIR}")
  endif()

  find_package(Threads REQUIRED)
  set(FFT_LIBRARIES ${MKL_RT_LIBRARY} Threads::Threads ${CMAKE_DL_LIBS} m)
  set(FFT_BACKEND_NAME "Intel MKL (FFTW3 interface)")

elseif(FFT_BACKEND STREQUAL "AOCL")
  if(DEFINED ENV{AOCL_ROOT})
    set(AOCL_ROOT_DIR $ENV{AOCL_ROOT})
  elseif(DEFINED ENV{AOCLFFT_ROOT})
    set(AOCL_ROOT_DIR $ENV{AOCLFFT_ROOT})
  else()
    message(FATAL_ERROR "AOCL_ROOT (or AOCLFFT_ROOT) is not set. Point it at your "
                         "AOCL / amd-fftw installation (the one shipping fftw3.f03).")
  endif()

  find_path(FFT_INCLUDE_DIRS fftw3.f03
    HINTS ${AOCL_ROOT_DIR}/include ${AOCL_ROOT_DIR}/amd-fftw/include)
  find_library(FFT_LIBRARIES NAMES fftw3 aoclfftw
    HINTS ${AOCL_ROOT_DIR}/lib ${AOCL_ROOT_DIR}/lib_LP64 ${AOCL_ROOT_DIR}/amd-fftw/lib)

  if(NOT FFT_INCLUDE_DIRS OR NOT FFT_LIBRARIES)
    message(FATAL_ERROR "Could not find an FFTW3-compatible fftw3.f03/library under "
                         "AOCL_ROOT=${AOCL_ROOT_DIR}. AOCL ships this as amd-fftw; "
                         "adjust the HINTS above to match your install layout if needed.")
  endif()
  set(FFT_BACKEND_NAME "AOCL-FFT (amd-fftw, FFTW3 interface)")

else()
  message(FATAL_ERROR "Unknown FFT_BACKEND '${FFT_BACKEND}'. Use FFTW, MKL, or AOCL.")
endif()

message(STATUS "FFT backend       : ${FFT_BACKEND_NAME}")
message(STATUS "FFT include dirs  : ${FFT_INCLUDE_DIRS}")
message(STATUS "FFT libraries     : ${FFT_LIBRARIES}")

# Small generated module carrying the backend name into the Fortran binary
# for the report header, so it prints which library it was linked against.
configure_file(${CMAKE_SOURCE_DIR}/src/fft_config.f90.in
               ${CMAKE_BINARY_DIR}/generated/fft_config.f90 @ONLY)

add_executable(fft3d_bench
  ${CMAKE_BINARY_DIR}/generated/fft_config.f90
  src/fft3d_bench.f90)

target_include_directories(fft3d_bench PRIVATE ${FFT_INCLUDE_DIRS})
target_link_libraries(fft3d_bench PRIVATE ${FFT_LIBRARIES})

enable_testing()
add_test(NAME fft3d_bench_smoke COMMAND fft3d_bench 16 32 --repeat=2 --estimate)
