"""
report.py  --  Poisson 1D Jacobi benchmark report generator.

Reads CSVs produced by benchmark.sh and writes an Excel workbook with
five analytical sheets:

  1. Compilador       serial_std vs serial_opt
  2. Cache            serial_std vs serial_cache
  3. Hilos            serial_std vs threads(2,4,6,8,12)
  4. Procesos         serial_std vs processes(2,4,6,8,12)
  5. Comparacion      Best representative of each strategy

Each sheet contains:
  Table 1  -- individual measurements (reps as rows, grid sizes as cols)
              with Avg / StdDev / CV% summary rows per impl block
  Table 2  -- per-impl average time + speedup over serial_std
  Two embedded charts (time and speedup)

Usage:
    python report.py [results_dir]
    Default: results_dir = results/
"""

from __future__ import annotations

import math
import os
import sys
from dataclasses import dataclass

import matplotlib.pyplot as plt
import pandas as pd
from openpyxl import Workbook
from openpyxl.drawing.image import Image as XLImage
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

from report_utils import (
    C, CHART_STYLE, FONT_NAME,
    Series,
    make_border, set_col_width,
    write_title_row, save_figure, plot_lines,
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

RESULTS_DIR = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "results"
OUTPUT_PATH = os.path.join(RESULTS_DIR, "reporte_poisson.xlsx")
CHARTS_DIR  = os.path.join(RESULTS_DIR, "charts")

SUITE_NAMES = ("serial", "compiler", "cache", "parallel")

IMPL_COLORS: dict[str, str] = {
    "serial_std":    "#FF6600",
    "serial_opt":    "#C00000",
    "serial_cache":  "#2E75B6",
    "threads_2":     "#BBBBBB",
    "threads_4":     "#70AD47",
    "threads_6":     "#4472C4",
    "threads_8":     "#ED7D31",
    "threads_12":    "#7030A0",
    "processes_2":   "#BBBBBB",
    "processes_4":   "#5CB85C",
    "processes_6":   "#337AB7",
    "processes_8":   "#F0AD4E",
    "processes_12":  "#9B59B6",
}

C_EXTRA: dict[str, str] = {
    "summary_bg":  "EBF3FB",
    "summary_fg":  "1F4E79",
    "impl_hdr":    "1F4E79",
    "sep":         "D9E1F2",
}

# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

# {Impl: {grid_size: [(rep, wall_time_ms), ...]}}
AllReps = dict["Impl", dict[int, list[tuple[int, float]]]]


@dataclass(frozen=True)
class Impl:
    name:        str
    parallelism: int

    @property
    def label(self) -> str:
        labels = {
            "serial_std":   "Secuencial estándar",
            "serial_opt":   "Secuencial optimizado (-O3 full)",
            "serial_cache": "Secuencial alineado a cache",
        }
        if self.name in labels:
            return labels[self.name]
        if self.name == "threads":
            return f"Hilos Jacobi ({self.parallelism} hilos)"
        if self.name == "processes":
            return f"Procesos fork ({self.parallelism} procesos)"
        return f"{self.name} ({self.parallelism})"

    @property
    def short_label(self) -> str:
        if self.parallelism == 0:
            return self.name
        return f"{self.name}_{self.parallelism}"

    @property
    def color(self) -> str:
        return IMPL_COLORS.get(self.short_label, "#888888")


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_suite_csv(suite: str) -> pd.DataFrame | None:
    path = os.path.join(RESULTS_DIR, f"data_{suite}.csv")
    if not os.path.exists(path):
        print(f"  [--]  {path} not found")
        return None
    df = pd.read_csv(path)
    df.columns         = [c.strip().lower() for c in df.columns]
    df["impl"]         = df["impl"].str.strip()
    df["parallelism"]  = df["parallelism"].astype(int)
    df["grid_size"]    = df["grid_size"].astype(int)
    df["repetition"]   = df["repetition"].astype(int)
    df["wall_time_ms"] = df["wall_time_ms"].astype(float)
    print(f"  [OK]  {path}  ({len(df)} rows)")
    return df


def build_all_reps(frames: list[pd.DataFrame]) -> AllReps:
    combined = pd.concat(frames, ignore_index=True)
    result: AllReps = {}
    for (name, par), grp in combined.groupby(["impl", "parallelism"]):
        impl = Impl(name=str(name), parallelism=int(str(par)))
        result[impl] = {}
        for size, sub in grp.groupby("grid_size"):
            result[impl][int(str(size))] = sorted(
                [(int(r), float(v))
                 for r, v in zip(sub["repetition"], sub["wall_time_ms"])],
                key=lambda x: x[0],
            )
    return result


def compute_avgs(all_reps: AllReps) -> dict[Impl, dict[int, float]]:
    return {
        impl: {s: sum(v for _, v in pairs) / len(pairs)
               for s, pairs in sizes.items()}
        for impl, sizes in all_reps.items()
    }


def best_parallel(avg_data: dict[Impl, dict[int, float]],
                  sizes: list[int], impl_name: str, ref: Impl) -> Impl | None:
    """Returns the parallel Impl with highest average speedup over ref."""
    ref_avgs = avg_data.get(ref, {})
    if not ref_avgs:
        return None
    best_impl, best_sp = None, 0.0
    for impl, times in avg_data.items():
        if impl.name != impl_name:
            continue
        sp_vals = [ref_avgs[s] / times[s]
                   for s in sizes
                   if s in times and s in ref_avgs and times[s] > 0]
        if sp_vals:
            sp = sum(sp_vals) / len(sp_vals)
            if sp > best_sp:
                best_sp, best_impl = sp, impl
    return best_impl


def size_label(n: int) -> str:
    if n >= 1_000_000 and n % 1_000_000 == 0:
        return f"{n // 1_000_000}M"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000 and n % 1_000 == 0:
        return f"{n // 1_000}K"
    return str(n)


# ---------------------------------------------------------------------------
# Cell styling helpers
# ---------------------------------------------------------------------------

def _thin_border() -> Border:
    s = Side(style="thin", color="BDD7EE")
    return Border(left=s, right=s, top=s, bottom=s)


def _thick_border() -> Border:
    thick = Side(style="medium", color="1F4E79")
    thin  = Side(style="thin",   color="BDD7EE")
    return Border(left=thick, right=thick, top=thin, bottom=thick)


def _hdr(cell, value: str, bg: str, fg: str = "FFFFFF",
         size: int = 10, bold: bool = True, align: str = "center") -> None:
    cell.value     = value
    cell.font      = Font(name=FONT_NAME, bold=bold, size=size, color=fg)
    cell.fill      = PatternFill("solid", fgColor=bg)
    cell.alignment = Alignment(horizontal=align, vertical="center",
                               wrap_text=True)
    cell.border    = _thin_border()


def _dat(cell, value, fmt: str | None = None,
         bg: str = "FFFFFF", fg: str = "000000",
         bold: bool = False, align: str = "right") -> None:
    cell.value     = value
    cell.font      = Font(name=FONT_NAME, bold=bold, size=10, color=fg)
    cell.fill      = PatternFill("solid", fgColor=bg)
    cell.alignment = Alignment(horizontal=align, vertical="center")
    cell.border    = _thin_border()
    if fmt:
        cell.number_format = fmt


def _summary_dat(cell, value, fmt: str | None = None,
                 bold: bool = False) -> None:
    _dat(cell, value, fmt=fmt,
         bg=C_EXTRA["summary_bg"], fg=C_EXTRA["summary_fg"], bold=bold)


# ---------------------------------------------------------------------------
# Chart generation
# ---------------------------------------------------------------------------

def chart_time(impls: list[Impl], avg_data: dict[Impl, dict[int, float]],
               sizes: list[int], title: str, fname: str) -> str:
    series = [
        Series(label=impl.short_label,
               data={s: avg_data[impl][s] for s in sizes
                     if s in avg_data.get(impl, {})},
               color=impl.color)
        for impl in impls if impl in avg_data
    ]
    with plt.rc_context(CHART_STYLE):
        fig, ax = plt.subplots(figsize=(9, 5))
        plot_lines(ax, [s for s in series if s.data], log_scale=True)
        ax.set_title(title, fontsize=12, fontweight="bold", pad=8)
        ax.set_xlabel("Tamaño de grilla (N)", fontsize=10)
        ax.set_ylabel("Tiempo promedio (ms)", fontsize=10)
        ax.legend(fontsize=8, loc="upper left")
        fig.tight_layout()
    return save_figure(fig, CHARTS_DIR, fname)


def chart_speedup(impls: list[Impl], avg_data: dict[Impl, dict[int, float]],
                  ref: Impl, sizes: list[int], title: str, fname: str) -> str:
    ref_avgs = avg_data.get(ref, {})
    series = []
    for impl in impls:
        if impl == ref or impl not in avg_data:
            continue
        data = {s: ref_avgs[s] / avg_data[impl][s]
                for s in sizes
                if s in avg_data[impl] and s in ref_avgs
                and avg_data[impl][s] > 0}
        if data:
            series.append(Series(label=impl.short_label,
                                 data=data, color=impl.color))
    with plt.rc_context(CHART_STYLE):
        fig, ax = plt.subplots(figsize=(9, 5))
        ax.axhline(1, color="#AAAAAA", lw=1.2, ls="--",
                   label=f"ref: {ref.short_label}")
        plot_lines(ax, series, log_scale=False)
        ax.set_title(title, fontsize=12, fontweight="bold", pad=8)
        ax.set_xlabel("Tamaño de grilla (N)", fontsize=10)
        ax.set_ylabel("Speedup", fontsize=10)
        ax.legend(fontsize=8, loc="upper left")
        fig.tight_layout()
    return save_figure(fig, CHARTS_DIR, fname)


# ---------------------------------------------------------------------------
# Sheet writer
# ---------------------------------------------------------------------------

def _write_raw_table(ws, impls: list[Impl], all_reps: AllReps,
                     sizes: list[int], n_cols: int,
                     start_row: int, n_reps: int) -> int:
    """Writes the per-impl raw measurement blocks. Returns next free row."""
    cur = start_row

    ws.merge_cells(f"A{cur}:{get_column_letter(n_cols)}{cur}")
    lbl = ws.cell(cur, 1, value="Tabla 1  —  Mediciones individuales (ms)")
    lbl.font      = Font(name=FONT_NAME, bold=True, size=11, color="FFFFFF")
    lbl.fill      = PatternFill("solid", fgColor=C["dark"])
    lbl.alignment = Alignment(horizontal="left", vertical="center")
    ws.row_dimensions[cur].height = 20
    cur += 1

    for impl_idx, impl in enumerate(impls):
        impl_reps = all_reps.get(impl, {})

        ws.merge_cells(f"A{cur}:{get_column_letter(n_cols)}{cur}")
        bh = ws.cell(cur, 1, value=impl.label)
        bh.font      = Font(name=FONT_NAME, bold=True, size=11, color="FFFFFF")
        bh.fill      = PatternFill("solid", fgColor=C_EXTRA["impl_hdr"])
        bh.alignment = Alignment(horizontal="left", vertical="center", indent=1)
        bh.border    = _thick_border()
        ws.row_dimensions[cur].height = 20
        cur += 1

        _hdr(ws.cell(cur, 1), "Rep", bg=C["mid"], size=9)
        for ci, size in enumerate(sizes, 2):
            _hdr(ws.cell(cur, ci), f"N = {size_label(size)}", bg=C["mid"], size=9)
        ws.row_dimensions[cur].height = 18
        cur += 1

        for rep in range(1, n_reps + 1):
            bg = C["alt"] if rep % 2 == 0 else "FFFFFF"
            _dat(ws.cell(cur, 1), rep, fmt="0",
                 bg=C["light"], bold=True, align="center")
            for ci, size in enumerate(sizes, 2):
                val = next(
                    (v for r, v in impl_reps.get(size, []) if r == rep),
                    None,
                )
                if val is not None:
                    _dat(ws.cell(cur, ci), round(val, 3),
                         fmt="#,##0.000", bg=bg)
                else:
                    _dat(ws.cell(cur, ci), "—", bg=bg, align="center")
            ws.row_dimensions[cur].height = 16
            cur += 1

        summary_defs = [
            ("Promedio",   "#,##0.000", 0),
            ("Desv. Est.", "#,##0.000", 1),
            ("CV (%)",     "0.00",      2),
        ]
        for s_label, fmt, s_idx in summary_defs:
            _hdr(ws.cell(cur, 1), s_label,
                 bg=C_EXTRA["summary_bg"], fg=C_EXTRA["summary_fg"],
                 size=9, align="left")
            for ci, size in enumerate(sizes, 2):
                vals = [v for _, v in impl_reps.get(size, [])]
                if vals:
                    mean = sum(vals) / len(vals)
                    std  = math.sqrt(
                        sum((v - mean) ** 2 for v in vals) / len(vals)
                    )
                    cv   = std / mean * 100 if mean > 0 else 0.0
                    show = mean if s_idx == 0 else (std if s_idx == 1 else cv)
                    _summary_dat(ws.cell(cur, ci),
                                 round(show, 3 if s_idx < 2 else 2),
                                 fmt=fmt, bold=(s_idx == 0))
                else:
                    _summary_dat(ws.cell(cur, ci), "—")
            ws.row_dimensions[cur].height = 16
            cur += 1

        if impl_idx < len(impls) - 1:
            for ci in range(1, n_cols + 1):
                ws.cell(cur, ci).fill = PatternFill(
                    "solid", fgColor=C_EXTRA["sep"])
            ws.row_dimensions[cur].height = 6
            cur += 1

    return cur


def _write_speedup_table(ws, impls: list[Impl],
                         avg_data: dict[Impl, dict[int, float]],
                         ref: Impl, sizes: list[int],
                         start_row: int) -> int:
    """Writes the speedup summary table. Returns next free row."""
    cur      = start_row
    n_sp_cols = 1 + len(sizes) * 2 + 1

    ws.merge_cells(f"A{cur}:{get_column_letter(n_sp_cols)}{cur}")
    sec = ws.cell(cur, 1,
                  value="Tabla 2  —  Promedio y Speedup  (ref: serial_std)")
    sec.font      = Font(name=FONT_NAME, bold=True, size=11, color="FFFFFF")
    sec.fill      = PatternFill("solid", fgColor=C["dark"])
    sec.alignment = Alignment(horizontal="left", vertical="center")
    ws.row_dimensions[cur].height = 20
    cur += 1

    set_col_width(ws, 1, 32)
    for si in range(len(sizes)):
        set_col_width(ws, 2 + si * 2, 13)
        set_col_width(ws, 3 + si * 2, 10)
    set_col_width(ws, n_sp_cols, 12)

    _hdr(ws.cell(cur, 1), "Implementación", bg=C["dark"], size=10)
    for si, size in enumerate(sizes):
        _hdr(ws.cell(cur, 2 + si * 2),
             f"N={size_label(size)}\nAvg (ms)", bg=C["mid"], size=9)
        _hdr(ws.cell(cur, 3 + si * 2),
             f"N={size_label(size)}\nSpeedup",  bg=C["mid"], size=9)
    _hdr(ws.cell(cur, n_sp_cols), "Speedup\nProm.", bg=C["dark"], size=9)
    ws.row_dimensions[cur].height = 28
    cur += 1

    ref_avgs = avg_data.get(ref, {})

    for ri, impl in enumerate(impls):
        bg     = C["alt"] if ri % 2 == 0 else "FFFFFF"
        is_ref = (impl == ref)
        times  = avg_data.get(impl, {})

        _dat(ws.cell(cur, 1), impl.label,
             bg=C["light"], bold=True, align="left")

        sp_refs: list[str] = []
        for si, size in enumerate(sizes):
            ac, sc  = 2 + si * 2, 3 + si * 2
            avg     = times.get(size)
            ref_avg = ref_avgs.get(size)

            avg_c               = ws.cell(cur, ac)
            avg_c.value         = round(avg, 3) if avg is not None else "N/A"
            avg_c.number_format = "#,##0.000"
            avg_c.font          = Font(name=FONT_NAME, size=10)
            avg_c.fill          = PatternFill("solid", fgColor=bg)
            avg_c.alignment     = Alignment(horizontal="right",
                                            vertical="center")
            avg_c.border        = _thin_border()

            sp_c = ws.cell(cur, sc)
            if is_ref:
                sp_c.value = 1.0
            elif avg and avg > 0 and ref_avg:
                sp_c.value = round(ref_avg / avg, 4)
            else:
                sp_c.value = "N/A"
            sp_c.number_format = "0.0000"
            sp_c.font      = Font(name=FONT_NAME, size=10,
                                  color=C["green_fg"])
            sp_c.fill      = PatternFill("solid", fgColor=C["green_bg"])
            sp_c.alignment = Alignment(horizontal="right", vertical="center")
            sp_c.border    = _thin_border()

            if not is_ref:
                sp_refs.append(f"{get_column_letter(sc)}{cur}")

        avsp           = ws.cell(cur, n_sp_cols)
        avsp.value     = (f"=IFERROR(AVERAGE({','.join(sp_refs)}),\"N/A\")"
                          if sp_refs else 1.0)
        avsp.number_format = "0.00"
        avsp.font      = Font(name=FONT_NAME, bold=True, size=10,
                              color=C["green_fg"])
        avsp.fill      = PatternFill("solid", fgColor=C["green_bg"])
        avsp.alignment = Alignment(horizontal="right", vertical="center")
        avsp.border    = _thin_border()
        ws.row_dimensions[cur].height = 17
        cur += 1

    return cur


def write_sheet(wb: Workbook, sheet_name: str, title: str,
                impls: list[Impl], all_reps: AllReps,
                ref: Impl, sizes: list[int],
                chart_time_path: str, chart_sp_path: str) -> None:
    ws      = wb.create_sheet(sheet_name)
    avg_data = compute_avgs(all_reps)
    n_reps  = max(
        (len(pairs) for impl in impls
         for pairs in all_reps.get(impl, {}).values()),
        default=10,
    )
    n_raw_cols = 1 + len(sizes)

    write_title_row(ws, title, n_raw_cols)
    ws.row_dimensions[1].height = 26

    set_col_width(ws, 1, 8)
    for ci in range(2, n_raw_cols + 1):
        set_col_width(ws, ci, 14)

    cur = _write_raw_table(ws, impls, all_reps, sizes,
                           n_raw_cols, start_row=2, n_reps=n_reps)
    cur += 2
    cur = _write_speedup_table(ws, impls, avg_data, ref, sizes,
                               start_row=cur)

    chart_anchor = cur + 3
    for anchor, path in [
        (f"A{chart_anchor}", chart_time_path),
        (f"L{chart_anchor}", chart_sp_path),
    ]:
        if path and os.path.exists(path):
            img        = XLImage(path)
            img.width  = 620
            img.height = 360
            ws.add_image(img, anchor)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    os.makedirs(CHARTS_DIR, exist_ok=True)

    print("Reading CSVs...")
    frames = []
    for suite in SUITE_NAMES:
        df = load_suite_csv(suite)
        if df is not None:
            frames.append(df)

    if not frames:
        print("No data found. Run benchmark.sh first.")
        sys.exit(1)

    all_reps = build_all_reps(frames)
    avg_data = compute_avgs(all_reps)
    sizes    = sorted({s for sizes in all_reps.values() for s in sizes})

    REF = Impl("serial_std", 0)

    def present(impl: Impl) -> bool:
        return impl in all_reps

    thread_counts  = sorted({i.parallelism for i in all_reps
                              if i.name == "threads"})
    process_counts = sorted({i.parallelism for i in all_reps
                              if i.name == "processes"})

    impls_compiler  = [i for i in [REF, Impl("serial_opt",   0)] if present(i)]
    impls_cache     = [i for i in [REF, Impl("serial_cache", 0)] if present(i)]
    impls_threads   = [REF] + [Impl("threads",   t) for t in thread_counts
                                if present(Impl("threads",   t))]
    impls_processes = [REF] + [Impl("processes", p) for p in process_counts
                                if present(Impl("processes", p))]

    best_t = best_parallel(avg_data, sizes, "threads",   REF)
    best_p = best_parallel(avg_data, sizes, "processes", REF)
    impls_final = [i for i in [
        REF,
        Impl("serial_opt",   0),
        Impl("serial_cache", 0),
        best_t,
        best_p,
    ] if i is not None and present(i)]

    print("\nGenerating charts...")

    def gen(prefix: str, impls: list[Impl], ref: Impl,
            t_title: str, s_title: str) -> tuple[str, str]:
        ct = chart_time(impls, avg_data, sizes, t_title, f"{prefix}_time.png")
        cs = chart_speedup(impls, avg_data, ref, sizes,
                           s_title, f"{prefix}_sp.png")
        print(f"  {os.path.basename(ct)}  |  {os.path.basename(cs)}")
        return ct, cs

    ct1, cs1 = gen("compilador", impls_compiler, REF,
                   "Tiempo  |  serial_std vs serial_opt",
                   "Speedup  |  T(serial_std) / T(serial_opt)")
    ct2, cs2 = gen("cache", impls_cache, REF,
                   "Tiempo  |  serial_std vs serial_cache",
                   "Speedup  |  T(serial_std) / T(serial_cache)")
    ct3, cs3 = gen("hilos", impls_threads, REF,
                   "Tiempo  |  serial_std vs threads(N)",
                   "Speedup  |  T(serial_std) / T(threads_N)")
    ct4, cs4 = gen("procesos", impls_processes, REF,
                   "Tiempo  |  serial_std vs processes(N)",
                   "Speedup  |  T(serial_std) / T(processes_N)")
    ct5, cs5 = gen("final", impls_final, REF,
                   "Tiempo  |  Comparación final por estrategia",
                   "Speedup  |  Mejor de cada estrategia  |  ref = serial_std")

    print("\nBuilding workbook...")
    wb = Workbook()
    if (default := wb.active) is not None:
        wb.remove(default)

    write_sheet(wb, "1. Compilador",
                "Compilador  |  serial_std  vs  serial_opt (-O3 full)",
                impls_compiler, all_reps, REF, sizes, ct1, cs1)
    write_sheet(wb, "2. Cache",
                "Cache  |  serial_std  vs  serial_cache (aligned_alloc)",
                impls_cache, all_reps, REF, sizes, ct2, cs2)
    write_sheet(wb, "3. Hilos",
                "Hilos  |  serial_std  vs  threads(2,4,6,8,12)  |  ref = serial_std",
                impls_threads, all_reps, REF, sizes, ct3, cs3)
    write_sheet(wb, "4. Procesos",
                "Procesos  |  serial_std  vs  processes(2,4,6,8,12)  |  ref = serial_std",
                impls_processes, all_reps, REF, sizes, ct4, cs4)
    write_sheet(wb, "5. Comparacion final",
                "Comparación final  |  Mejor de cada estrategia  |  ref = serial_std",
                impls_final, all_reps, REF, sizes, ct5, cs5)

    wb.save(OUTPUT_PATH)
    print(f"\nSaved: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()