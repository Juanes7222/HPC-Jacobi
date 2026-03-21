#!/usr/bin/env bash
# =============================================================================
# benchmark.sh  --  Poisson 1D Jacobi: parallel benchmark
#
# Suite 1 - parallel   : serial  vs  threads(2,4,6,8,12)  vs  processes(2,4,6,8,12)
#           Compares shared-memory threading against fork+mmap processes.
#
# Usage:
#   ./benchmark.sh [parallel|all]   (default: all)
#
# Output (per suite):
#   results/data_<suite>.csv
#   results/summary_<suite>.txt
#
# Binaries expected in the same directory:
#   ./serial    <n> <max_iters>
#   ./threads   <n> <max_iters> <n_threads>
#   ./processes <n> <max_iters> <n_procs>
#
# Each binary prints a single float (wall time in ms) to stdout.
# Human-readable info goes to stderr.
# =============================================================================

set -euo pipefail
export LC_NUMERIC=C

# Resolve the directory where this script lives so the script can be
# invoked from any working directory (e.g. sudo bash /path/to/benchmark.sh).
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

RESULTS_DIR="results"
GRID_SIZES=(500 1000 2000 4000 8000)
MAX_ITERS=5000
REPETITIONS=5
PARALLEL_COUNTS=(2 4 6 8 12)

CSV_HEADER="suite,impl,parallelism,grid_size,repetition,wall_time_ms"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
BOLD="\033[1m"
GREEN="\033[0;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

log_info()    { echo -e "  ${CYAN}>${RESET} $*"; }
log_ok()      { echo -e "  ${GREEN}[ok]${RESET} $*"; }
log_error()   { echo -e "  ${RED}[error]${RESET} $*" >&2; }
log_section() { echo -e "\n${BOLD}-- $* ${RESET}"; }

# ---------------------------------------------------------------------------
# CSV helpers
# ---------------------------------------------------------------------------
setup_csv() {
    local csv="$1" header="$2"
    mkdir -p "${RESULTS_DIR}"
    if [[ ! -f "${csv}" ]]; then
        echo "${header}" > "${csv}"
        log_info "Created: ${csv}"
    else
        log_info "Appending to existing: ${csv}"
    fi
}

row_exists() {
    local csv="$1" suite="$2" impl="$3" par="$4" size="$5" rep="$6"
    awk -F',' -v su="$suite" -v im="$impl" -v pa="$par" \
              -v si="$size"  -v re="$rep" \
        'NR>1 && $1==su && $2==im && $3==pa && $4==si && $5==re { found=1 }
         END { print found+0 }' "${csv}" 2>/dev/null
}

write_row() {
    local csv="$1" suite="$2" impl="$3" par="$4" size="$5" rep="$6" ms="$7"
    printf '%s,%s,%s,%s,%s,%s\n' \
        "${suite}" "${impl}" "${par}" "${size}" "${rep}" "${ms}" >> "${csv}"
    sync
}

# ---------------------------------------------------------------------------
# Single run: captures stdout (ms); human output goes to stderr
# ---------------------------------------------------------------------------
run_once() {
    local bin="$1" size="$2" par="$3"
    local ms err exit_code=0
    local errfile
    errfile=$(mktemp)

    if [[ "${par}" -eq 0 ]]; then
        ms=$("${bin}" "${size}" "${MAX_ITERS}" 2>"${errfile}") || exit_code=$?
    else
        ms=$("${bin}" "${size}" "${MAX_ITERS}" "${par}" 2>"${errfile}") || exit_code=$?
    fi

    if [[ -s "${errfile}" ]]; then
        # Human-readable binary output -> forward to terminal stderr
        cat "${errfile}" >&2
    fi
    rm -f "${errfile}"

    if [[ -z "${ms}" || "${exit_code}" -ne 0 ]]; then
        log_error "Binary failed (exit=${exit_code}): ${bin} ${size} ${MAX_ITERS} ${par}"
        echo "0.000"
    else
        echo "${ms}"
    fi
}

# ---------------------------------------------------------------------------
# Generic measurement loop
# ---------------------------------------------------------------------------
# entries format: "impl|binary_path|parallelism"
#   parallelism == 0 means serial (no 3rd argument to the binary)
measure_entries() {
    local suite="$1"
    local csv="${RESULTS_DIR}/data_${suite}.csv"
    shift
    local entries=("$@")

    setup_csv "${csv}" "${CSV_HEADER}"

    for entry in "${entries[@]}"; do
        local impl bin par
        impl=$(echo "${entry}" | cut -d'|' -f1)
        bin=$(echo  "${entry}" | cut -d'|' -f2)
        par=$(echo  "${entry}" | cut -d'|' -f3)

        local label="${impl}"
        [[ "${par}" -gt 0 ]] && label="${impl}(${par})"
        log_section "Measuring: ${label}"

        for rep in $(seq 1 "${REPETITIONS}"); do
            for size in "${GRID_SIZES[@]}"; do
                if [[ "$(row_exists "${csv}" "${suite}" "${impl}" \
                        "${par}" "${size}" "${rep}")" -gt 0 ]]; then
                    log_info "[skip] ${label} n=${size} rep=${rep}"
                    continue
                fi

                printf "    rep=%-2s  n=%-6s  " "${rep}" "${size}"
                local ms
                ms=$(run_once "${bin}" "${size}" "${par}")
                printf "%s ms\n" "${ms}"

                write_row "${csv}" "${suite}" "${impl}" \
                          "${par}" "${size}" "${rep}" "${ms}"
            done
        done
    done
}

# ---------------------------------------------------------------------------
# Summary: averages + speedup over serial reference
# ---------------------------------------------------------------------------
print_summary() {
    local suite="$1"
    local csv="${RESULTS_DIR}/data_${suite}.csv"
    local summary="${RESULTS_DIR}/summary_${suite}.txt"
    local tmpavg="${RESULTS_DIR}/.avgs_${suite}.tmp"

    awk -F',' '
    NR==1 { next }
    {
        key = $2 SUBSEP $3 SUBSEP $4
        sum[key] += $6
        cnt[key]++
    }
    END {
        for (k in sum) {
            split(k, a, SUBSEP)
            printf "%s|%s|%s|%.3f\n", a[1], a[2], a[3], sum[k]/cnt[k]
        }
    }' "${csv}" | sort -t'|' -k1,1 -k2,2n -k3,3n > "${tmpavg}"

    # Reference: serial (par=0) per grid size
    declare -A REF_AVG
    while IFS='|' read -r impl par size avg; do
        [[ "${impl}" == "serial" && "${par}" -eq 0 ]] && REF_AVG["${size}"]="${avg}"
    done < "${tmpavg}"

    {
        echo ""
        echo "Suite       : ${suite}"
        echo "Date        : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host        : $(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
        echo "GCC         : $(gcc --version | head -1)"
        echo "Grid sizes  : ${GRID_SIZES[*]}"
        echo "Max iters   : ${MAX_ITERS}"
        echo "Repetitions : ${REPETITIONS}"
        echo "Reference   : serial"
        echo ""
        echo "Average wall time (ms)"
        printf '%0.s=' {1..90}; echo ""
        printf "%-22s" "Impl (parallelism)"
        for size in "${GRID_SIZES[@]}"; do
            printf "  %10s" "n=${size}"
        done
        printf "  %10s\n" "Avg Speedup"
        printf "%-22s" "----------------------"
        for size in "${GRID_SIZES[@]}"; do
            printf "  %10s" "----------"
        done
        printf "  %10s\n" "----------"

        declare -A ROW_AVG ROW_ORDER
        while IFS='|' read -r impl par size avg; do
            local key="${impl}|${par}"
            ROW_AVG["${key}:${size}"]="${avg}"
            ROW_ORDER["${key}"]="${impl}|${par}"
        done < "${tmpavg}"

        IFS=$'\n' sorted_keys=($(printf '%s\n' "${!ROW_ORDER[@]}" \
            | awk -F'|' '{ order=($1=="serial"?0:$1=="threads"?1:2); print order"|"$2"|"$0 }' \
            | sort -t'|' -k1,1n -k2,2n \
            | cut -d'|' -f3-))
        unset IFS

        for key in "${sorted_keys[@]}"; do
            IFS='|' read -r impl par <<< "${key}"
            local label="${impl}"
            [[ "${par}" -gt 0 ]] && label="${impl}(${par})"
            printf "%-22s" "${label}"

            local sp_sum=0 sp_cnt=0
            for size in "${GRID_SIZES[@]}"; do
                local avg="${ROW_AVG[${key}:${size}]:-}"
                if [[ -z "${avg}" ]]; then
                    printf "  %10s" "N/A"
                    continue
                fi
                printf "  %10.1f" "${avg}"

                local ref="${REF_AVG[${size}]:-}"
                if [[ -n "${ref}" && "${avg}" != "0.000" ]]; then
                    local sp
                    sp=$(awk "BEGIN { printf \"%.4f\", ${ref}/${avg} }")
                    sp_sum=$(awk "BEGIN { printf \"%.4f\", ${sp_sum}+${sp} }")
                    sp_cnt=$(( sp_cnt + 1 ))
                fi
            done

            if (( sp_cnt > 0 )); then
                local avg_sp
                avg_sp=$(awk "BEGIN { printf \"%.3f\", ${sp_sum}/${sp_cnt} }")
                printf "  %10sx\n" "${avg_sp}"
            else
                printf "  %10s\n" "N/A"
            fi
        done

        echo ""
        echo "Speedup = T(serial) / T(row)  [>1 means faster than serial]"
        printf '%0.s=' {1..90}; echo ""
    } | tee "${summary}"

    rm -f "${tmpavg}"
    log_ok "Summary : ${summary}"
    log_ok "Raw data: ${csv}"
}

# ---------------------------------------------------------------------------
# Suite: serial vs threads(2,4,6,8,12) vs processes(2,4,6,8,12)
# ---------------------------------------------------------------------------
run_suite_parallel() {
    local entries=()
    entries+=("serial|./serial|0")
    for p in "${PARALLEL_COUNTS[@]}"; do
        entries+=("threads|./threads|${p}")
    done
    for p in "${PARALLEL_COUNTS[@]}"; do
        entries+=("processes|./processes|${p}")
    done

    measure_entries "parallel" "${entries[@]}"
    print_summary "parallel"
}


# ---------------------------------------------------------------------------
# System optimization / restore
# ---------------------------------------------------------------------------

_DM_UNIT=""

_detect_display_manager() {
    local candidates=(sddm gdm gdm3 lightdm ly greetd)
    for dm in "${candidates[@]}"; do
        if systemctl is-active --quiet "${dm}.service" 2>/dev/null; then
            echo "${dm}.service"
            return
        fi
    done
    echo ""
}

optimize_system() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "Run as root to apply system optimizations (sudo ./benchmark.sh)"
        log_error "Continuing without optimizations."
        return
    fi

    log_section "Applying system optimizations"

    _DM_UNIT="$(_detect_display_manager)"
    if [[ -n "${_DM_UNIT}" ]]; then
        log_info "Stopping display manager: ${_DM_UNIT}"
        systemctl stop "${_DM_UNIT}"
    else
        log_info "No active display manager detected"
    fi

    log_info "Isolating multi-user.target (dropping GUI)"
    systemctl isolate multi-user.target

    log_info "Setting CPU governor: performance"
    echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null

    # Disable boost: AMD path first, then Intel fallback
    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        log_info "Disabling AMD CPU boost"
        echo 0 > /sys/devices/system/cpu/cpufreq/boost
    elif [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        log_info "Disabling Intel turbo boost"
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo
    fi

    log_ok "System ready for benchmarking"
}

restore_system() {
    if [[ "${EUID}" -ne 0 ]]; then
        return
    fi

    log_section "Restoring system"

    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        log_info "Restoring CPU governor: powersave"
        echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null
    fi

    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        log_info "Re-enabling AMD CPU boost"
        echo 1 > /sys/devices/system/cpu/cpufreq/boost
    elif [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        log_info "Re-enabling Intel turbo boost"
        echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo
    fi

    log_info "Restoring graphical.target"
    systemctl isolate graphical.target

    if [[ -n "${_DM_UNIT}" ]]; then
        log_info "Starting display manager: ${_DM_UNIT}"
        systemctl start "${_DM_UNIT}"
    fi

    log_ok "System restored"
}

# ---------------------------------------------------------------------------
print_banner() {
    echo -e "${BOLD}"
    echo "================================================================"
    echo "   Poisson 1D Jacobi -- Parallel Benchmark"
    echo "   Grid sizes   : ${GRID_SIZES[*]}"
    echo "   Max iters    : ${MAX_ITERS}"
    echo "   Repetitions  : ${REPETITIONS}"
    echo "   Parallelism  : ${PARALLEL_COUNTS[*]}"
    echo "   Date         : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================"
    echo -e "${RESET}"
}

# ---------------------------------------------------------------------------
check_and_compile() {
    local missing=0
    for bin in serial threads processes; do
        if [[ ! -x "${SCRIPT_DIR}/${bin}" ]]; then
            log_info "Binary not found: ${bin}"
            missing=1
        fi
    done

    if [[ "${missing}" -eq 1 ]]; then
        log_section "Compiling binaries"
        if [[ ! -f "${SCRIPT_DIR}/Makefile" ]]; then
            log_error "Makefile not found in ${SCRIPT_DIR}. Run 'make' manually first."
            exit 1
        fi
        make -C "${SCRIPT_DIR}" 2>&1 | sed 's/^/  /'
        log_ok "Compilation complete"
    else
        log_info "All binaries present"
    fi
}

main() {
    local suite="${1:-all}"
    cd "${SCRIPT_DIR}"
    mkdir -p "${RESULTS_DIR}"

    check_and_compile

    trap restore_system EXIT
    optimize_system

    print_banner

    case "${suite}" in
        parallel|all)
            run_suite_parallel
            ;;
        *)
            log_error "Unknown suite: '${suite}'"
            log_error "Options: parallel | all"
            exit 1
            ;;
    esac
}


main "$@"