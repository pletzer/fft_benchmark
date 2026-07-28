! 3D double-precision complex-to-complex FFT benchmark.
!
! Written against the FFTW3 Fortran 2003 interface (fftw3.f03, "fftw_*"
! double-precision symbols), which FFTW3, Intel MKL, and AOCL/amd-fftw all
! provide, so the exact same binary logic runs against whichever backend
! CMake was configured with (-DFFT_BACKEND=FFTW|MKL|AOCL).
!
! Usage:
!   fft3d_bench N1 [N2 N3 ...] [--repeat=R] [--estimate]
!
!   N1 N2 ...   one or more grid sizes; each produces an N x N x N complex
!               grid (same size in all three dimensions).
!   --repeat=R  number of timed forward-transform executions per size
!               (default 5); the minimum time over R runs is reported.
!   --estimate  use FFTW_ESTIMATE for planning instead of the default
!               FFTW_MEASURE (faster to plan, less representative of the
!               library's best achievable performance).
program fft3d_bench
  use, intrinsic :: iso_c_binding
  use fft_config, only: backend_name
  implicit none
  include 'fftw3.f03'

  integer, parameter :: dp = c_double

  integer, allocatable :: sizes(:)
  integer :: nsizes, repeat_count, isz
  logical :: use_estimate

  call parse_args(sizes, nsizes, repeat_count, use_estimate)

  if (nsizes == 0) then
    print '(A)', "Usage: fft3d_bench N1 [N2 N3 ...] [--repeat=R] [--estimate]"
    stop 1
  end if

  print '(A)', "================================================================"
  print '(A,A)',   " 3D FFT benchmark  —  backend: ", trim(backend_name)
  print '(A,I0)',  " repeats per size (min of)   : ", repeat_count
  print '(A,A)',   " planning mode                : ", &
       merge("FFTW_ESTIMATE", "FFTW_MEASURE ", use_estimate)
  print '(A)', "================================================================"
  print '(A)', ""
  print '(A8,A14,A14,A16,A14)', "N", "time(ms)", "GFLOP/s", "roundtrip err", "N^3 (Mi elem)"

  do isz = 1, nsizes
    call run_case(sizes(isz), repeat_count, use_estimate)
  end do

contains

  subroutine run_case(n, nrep, estimate)
    integer, intent(in) :: n
    integer, intent(in) :: nrep
    logical, intent(in) :: estimate

    integer(C_SIZE_T) :: ntot
    integer :: plan_flags, r
    type(C_PTR) :: p_orig, p_in, p_out
    type(C_PTR) :: plan_fwd, plan_bwd
    complex(C_DOUBLE_COMPLEX), pointer :: orig(:,:,:), in(:,:,:), out(:,:,:)
    integer(kind=8) :: count_start, count_end, count_rate
    real(dp) :: dt, best, flop_estimate, gflops, err

    ntot = int(n, C_SIZE_T) * int(n, C_SIZE_T) * int(n, C_SIZE_T)

    p_orig = fftw_alloc_complex(ntot)
    p_in   = fftw_alloc_complex(ntot)
    p_out  = fftw_alloc_complex(ntot)
    call c_f_pointer(p_orig, orig, [n, n, n])
    call c_f_pointer(p_in,   in,   [n, n, n])
    call c_f_pointer(p_out,  out,  [n, n, n])

    if (estimate) then
      plan_flags = FFTW_ESTIMATE
    else
      plan_flags = FFTW_MEASURE
    end if

    ! Plan first (may run trial transforms on whatever garbage is in in/out),
    ! then fill the real signal afterwards so planning can never affect it.
    plan_fwd = fftw_plan_dft_3d(n, n, n, in, out, FFTW_FORWARD, plan_flags)
    plan_bwd = fftw_plan_dft_3d(n, n, n, out, in, FFTW_BACKWARD, plan_flags)

    call init_signal(orig, n)
    in = orig

    ! Untimed warm-up.
    call fftw_execute_dft(plan_fwd, in, out)

    best = huge(best)
    do r = 1, nrep
      call system_clock(count_start, count_rate)
      call fftw_execute_dft(plan_fwd, in, out)
      call system_clock(count_end)
      dt = real(count_end - count_start, dp) / real(count_rate, dp)
      best = min(best, dt)
    end do

    ! Round-trip correctness check (unnormalized inverse: divide by ntot).
    call fftw_execute_dft(plan_bwd, out, in)
    err = maxval(abs(in / real(ntot, dp) - orig))

    ! Standard FFT flop-count heuristic: 5 * Ntotal * log2(Ntotal).
    flop_estimate = 5.0_dp * real(ntot, dp) * log(real(ntot, dp)) / log(2.0_dp)
    gflops = flop_estimate / (best * 1.0e9_dp)

    print '(I8,F14.4,F14.3,ES16.3,F14.2)', &
         n, best * 1.0e3_dp, gflops, err, real(ntot, dp) / 1048576.0_dp

    call fftw_destroy_plan(plan_fwd)
    call fftw_destroy_plan(plan_bwd)
    call fftw_free(p_orig)
    call fftw_free(p_in)
    call fftw_free(p_out)
  end subroutine run_case

  subroutine init_signal(a, n)
    complex(C_DOUBLE_COMPLEX), intent(out) :: a(:,:,:)
    integer, intent(in) :: n
    integer :: i, j, k
    real(dp), parameter :: twopi = 6.283185307179586_dp
    real(dp) :: fi, fj, fk, rn

    rn = real(n, dp)
    do k = 1, n
      fk = twopi * real(k - 1, dp) / rn
      do j = 1, n
        fj = twopi * real(j - 1, dp) / rn
        do i = 1, n
          fi = twopi * real(i - 1, dp) / rn
          a(i, j, k) = cmplx(sin(fi) * cos(fj) * sin(2.0_dp * fk), &
                              cos(2.0_dp * fi) * sin(fj), kind=dp)
        end do
      end do
    end do
  end subroutine init_signal

  subroutine parse_args(out_sizes, out_n, out_repeat, out_estimate)
    integer, allocatable, intent(out) :: out_sizes(:)
    integer, intent(out) :: out_n
    integer, intent(out) :: out_repeat
    logical, intent(out) :: out_estimate

    integer :: nargs, i, ios, val, count_numeric
    character(len=256) :: arg

    out_repeat = 5
    out_estimate = .false.
    nargs = command_argument_count()

    count_numeric = 0
    do i = 1, nargs
      call get_command_argument(i, arg)
      if (is_numeric(trim(arg))) count_numeric = count_numeric + 1
    end do

    allocate(out_sizes(count_numeric))
    out_n = 0

    do i = 1, nargs
      call get_command_argument(i, arg)
      arg = trim(arg)
      if (arg == "--estimate") then
        out_estimate = .true.
      else if (len(arg) > 9 .and. arg(1:9) == "--repeat=") then
        read(arg(10:), *, iostat=ios) val
        if (ios /= 0 .or. val < 1) then
          print '(A,A)', "Invalid --repeat= value: ", trim(arg)
          stop 1
        end if
        out_repeat = val
      else if (is_numeric(arg)) then
        read(arg, *, iostat=ios) val
        if (ios /= 0 .or. val < 1) then
          print '(A,A)', "Invalid grid size: ", trim(arg)
          stop 1
        end if
        out_n = out_n + 1
        out_sizes(out_n) = val
      else
        print '(A,A)', "Unrecognized argument: ", trim(arg)
        stop 1
      end if
    end do
  end subroutine parse_args

  logical function is_numeric(s)
    character(len=*), intent(in) :: s
    integer :: ios, v
    if (len_trim(s) == 0) then
      is_numeric = .false.
      return
    end if
    read(s, *, iostat=ios) v
    is_numeric = (ios == 0)
  end function is_numeric

end program fft3d_bench
