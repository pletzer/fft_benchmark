#!/usr/bin/env python3
"""Plot FFTW vs MKL vs AOCL 3D-FFT benchmark results.

Reads every *.csv produced by fft3d_bench --csv (one file per backend, each
with header "backend,plan,N,repeat,time_ms,gflops,roundtrip_err") from a
results directory and plots GFLOP/s and time vs grid size N for each
backend on log-log axes.
"""
import argparse
import glob
import os
import sys

import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# Canonical short legend label + styling, keyed by the exact backend_name
# string baked into each build via CMake's FFT_BACKEND_NAME (see
# CMakeLists.txt). Using a fixed short label here -- rather than deriving
# one from the raw string -- keeps the legend unambiguous even if those
# descriptive strings change.
BACKEND_STYLE = {
    "FFTW3": {"label": "FFTW", "color": "#1b9e77", "marker": "o"},
    "Intel MKL (FFTW3 interface)": {"label": "MKL", "color": "#d95f02", "marker": "s"},
    "AOCL-FFT (amd-fftw)": {"label": "AOCL", "color": "#7570b3", "marker": "^"},
}


def style_for(backend):
    if backend in BACKEND_STYLE:
        return BACKEND_STYLE[backend]
    # Unrecognized backend string (e.g. FFT_BACKEND_NAME was changed) --
    # fall back to a short label instead of crashing.
    return {"label": backend.split(" (")[0], "color": None, "marker": "o"}


def load_results(results_dir):
    csv_files = sorted(glob.glob(os.path.join(results_dir, "*.csv")))
    if not csv_files:
        sys.exit(f"No CSV files found in {results_dir}")

    frames = []
    for f in csv_files:
        df = pd.read_csv(f)
        frames.append(df)
    data = pd.concat(frames, ignore_index=True)
    data = data.sort_values(["backend", "N"])
    return data


def plot(data, out_path):
    backends = list(data["backend"].unique())

    fig, (ax_gflops, ax_time) = plt.subplots(1, 2, figsize=(11, 4.5))

    for backend in backends:
        sub = data[data["backend"] == backend]
        style = style_for(backend)
        ax_gflops.plot(sub["N"], sub["gflops"], marker=style["marker"],
                        color=style["color"], label=style["label"])
        ax_time.plot(sub["N"], sub["time_ms"], marker=style["marker"],
                     color=style["color"], label=style["label"])

    ax_gflops.set_xscale("log", base=2)
    ax_gflops.set_xlabel("Grid size N (N x N x N)")
    ax_gflops.set_ylabel("GFLOP/s (higher is better)")
    ax_gflops.set_title("3D FFT throughput")
    ax_gflops.grid(True, which="both", alpha=0.3)
    ax_gflops.legend()

    ax_time.set_xscale("log", base=2)
    ax_time.set_yscale("log")
    ax_time.set_xlabel("Grid size N (N x N x N)")
    ax_time.set_ylabel("Time per forward FFT (ms, lower is better)")
    ax_time.set_title("3D FFT wall time")
    ax_time.grid(True, which="both", alpha=0.3)
    ax_time.legend()

    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    print(f"Wrote {out_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-dir", required=True, help="Directory containing *.csv result files")
    parser.add_argument("--out", required=True, help="Output image path (e.g. comparison.png)")
    args = parser.parse_args()

    data = load_results(args.results_dir)
    plot(data, args.out)


if __name__ == "__main__":
    main()
