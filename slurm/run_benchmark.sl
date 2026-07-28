#!/bin/bash -e
#SBATCH --job-name=fft_bench
#SBATCH --account=nesi99999          # <-- set to your NeSI project code
#SBATCH --time=01:00:00
#SBATCH --partition=milan            # Mahuika AMD Milan CPU partition; `sinfo -o "%P %c %m"` to check
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err

# ---------------------------------------------------------------------------
# Builds fft3d_bench three times from the same source (FFTW, MKL, AOCL
# backends) and benchmarks 3D FFTs over a range of grid sizes on Mahuika.
#
# NOTE: Intel MKL dispatches to a slower code path on non-Intel CPUs (it
# checks the vendor string, not just the supported instruction set), so an
# MKL-vs-AOCL run on AMD Milan nodes is not a neutral "best case for both"
# comparison out of the box. That is itself a real, reportable data point
# -- just don't present it as MKL's best achievable performance.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIZES=(32 64 128 256 512)
REPEAT=10

RESULTS_DIR="$REPO_DIR/results/${SLURM_JOB_ID:-local}"
mkdir -p "$RESULTS_DIR"

# Single-threaded, apples-to-apples: this repo currently links the
# single-threaded FFTW3 API for all three backends.
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1

echo "Host        : $(hostname)"
echo "Grid sizes  : ${SIZES[*]}"
echo "Repeats     : $REPEAT"
echo "Results dir : $RESULTS_DIR"

build_backend () {
  local backend=$1
  local build_dir="$REPO_DIR/build-${backend,,}"

  echo "=== [$backend] configuring + building ==="
  rm -rf "$build_dir"
  cmake -S "$REPO_DIR" -B "$build_dir" -DFFT_BACKEND="$backend" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$build_dir" -j "${SLURM_CPUS_PER_TASK:-4}"
}

run_backend () {
  local backend=$1
  local build_dir="$REPO_DIR/build-${backend,,}"
  local csv="$RESULTS_DIR/${backend,,}.csv"

  echo "=== [$backend] running ==="
  "$build_dir/fft3d_bench" "${SIZES[@]}" --repeat="$REPEAT" --csv > "$csv"
  cat "$csv"
}

module purge

echo ""
echo "############ FFTW ############"
module load foss/2026
build_backend FFTW
run_backend FFTW
module purge

echo ""
echo "############ MKL (imkl-FFTW) ############"
module load foss/2026 imkl-FFTW
if [ -z "${MKLROOT:-}" ]; then
  # imkl-FFTW is expected to export MKLROOT itself; this is a fallback in
  # case that changes, mirroring the EasyBuild EBROOT<name> convention.
  for v in EBROOTIMKLMINFFTW EBROOTIMKL; do
    val="${!v:-}"
    if [ -n "$val" ]; then
      export MKLROOT="$val"
      break
    fi
  done
fi
echo "MKLROOT=${MKLROOT:-<unset -- build will fail, check 'module show imkl-FFTW'>}"
build_backend MKL
run_backend MKL
module purge

echo ""
echo "############ AOCL (AOCL-min-FFTW) ############"
module load foss/2026 AOCL-min-FFTW
echo "AOCL_ROOT=${AOCL_ROOT:-<unset>}  EBROOTAOCLMINFFTW=${EBROOTAOCLMINFFTW:-<unset>}"
build_backend AOCL
run_backend AOCL
module purge

echo ""
echo "############ Plotting ############"
module load Python/3.11.6-foss-2023a  # <-- adjust: `module spider Python` for one with matplotlib+pandas
python3 "$REPO_DIR/plot_results.py" --results-dir "$RESULTS_DIR" --out "$RESULTS_DIR/comparison.png"

echo ""
echo "Done. CSVs and plot in $RESULTS_DIR"
