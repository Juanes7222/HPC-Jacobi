#!/usr/bin/env bash
# =============================================================================
# benchmark.sh  --  Poisson 1D Jacobi: three experimental suites
#
# Suite 1 - compiler : serial_std  vs  serial_opt
#           Does compiler optimization alone beat parallelism?
#
# Suite 2 - cache    : serial_std  vs  serial_cache
#           Isolates the effect of cache-line alignment + prefetch.
#
# Suite 3 - parallel : serial_std  vs  threads(2,4,6,8,12)
#                                  vs  processes(2,4,6,8,12)
#           Compares shared-memory threading against fork+mmap processes.
#
# Usage:
#   sudo ./benchmark.sh [compiler|cache|parallel|all]   (default: all)
#
# Output (per suite):
#   results/data_<suite>.csv
#   results/summary_<suite>.txt
#
# Binaries (built by make):
#   ./serial_std    <n> <max_iters>
#   ./serial_opt    <n> <max_iters>
#   ./serial_cache  <n> <max_iters>
#   ./threads       <n> <max_iters> <n_threads>
#   ./processes     <n> <max_iters> <n_procs>
#
# Each binary prints a single float (wall time in ms) to stdout.
# Human-readable info goes to stderr.
# =============================================================================

set -euo pipefail
export LC_NUMERIC=C

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
        if systemctl stop "${_DM_UNIT}" 2>/dev/null; then
            log_ok "Display manager stopped"
        else
            log_error "Failed to stop ${_DM_UNIT}"
        fi
    else
        log_info "No active display manager detected"
    fi

    log_info "Isolating multi-user.target (dropping GUI)"
    if systemctl isolate multi-user.target 2>/dev/null; then
        log_ok "Switched to multi-user.target"
    else
        log_error "Failed to isolate multi-user.target"
    fi

    log_info "Setting CPU governor: performance"
    local gov_ok=0
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "${f}" ]] && echo performance > "${f}" && gov_ok=1
    done
    if (( gov_ok )); then
        log_ok "CPU governor set to performance"
    else
        log_error "Could not set CPU governor (path not found)"
    fi

    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        log_info "Disabling AMD CPU boost"
        if echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null; then
            log_ok "AMD boost disabled"
        else
            log_error "Failed to disable AMD boost"
        fi
    elif [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        log_info "Disabling Intel turbo boost"
        if echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null; then
            log_ok "Intel turbo disabled"
        else
            log_error "Failed to disable Intel turbo"
        fi
    else
        log_info "No boost control path found — skipping"
    fi

    log_ok "System ready for benchmarking"
}

restore_system() {
    if [[ "${EUID}" -ne 0 ]]; then
        return
    fi

    log_section "Restoring system"

    local gov_ok=0
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "${f}" ]] && echo powersave > "${f}" && gov_ok=1
    done
    if (( gov_ok )); then
        log_ok "CPU governor restored to powersave"
    fi

    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        log_info "Re-enabling AMD CPU boost"
        echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null             && log_ok "AMD boost re-enabled"             || log_error "Failed to re-enable AMD boost"
    elif [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        log_info "Re-enabling Intel turbo boost"
        echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null             && log_ok "Intel turbo re-enabled"             || log_error "Failed to re-enable Intel turbo"
    fi

    log_info "Restoring graphical.target"
    if systemctl isolate graphical.target 2>/dev/null; then
        log_ok "Switched back to graphical.target"
    else
        log_error "Failed to restore graphical.target"
    fi

    if [[ -n "${_DM_UNIT}" ]]; then
        log_info "Starting display manager: ${_DM_UNIT}"
        if systemctl start "${_DM_UNIT}" 2>/dev/null; then
            log_ok "Display manager started"
        else
            log_error "Failed to start ${_DM_UNIT}"
        fi
    fi

    log_ok "System restored"
}

# ---------------------------------------------------------------------------
# Pre-flight: compile if any binary is missing
# ---------------------------------------------------------------------------
check_and_compile() {
    local missing=0
    for bin in serial_std serial_opt serial_cache threads processes; do
        if [[ ! -x "${SCRIPT_DIR}/bin/${bin}" ]]; then
            log_info "Binary not found: ${bin}"
            missing=1
        fi
    done

    if [[ "${missing}" -eq 1 ]]; then
        log_section "Compiling binaries"
        if [[ ! -f "${SCRIPT_DIR}/Makefile" ]]; then
            log_error "Makefile not found in ${SCRIPT_DIR}. Run 'make' manually."
            exit 1
        fi
        make -C "${SCRIPT_DIR}" 2>&1 | sed 's/^/  /'
        log_ok "Compilation complete"
    else
        log_info "All binaries present"
    fi
}

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
# Single run
# ---------------------------------------------------------------------------
run_once() {
    local bin="$1" size="$2" par="$3"
    local ms errfile exit_code=0
    errfile=$(mktemp)

    if [[ "${par}" -eq 0 ]]; then
        ms=$("${bin}" "${size}" "${MAX_ITERS}" 2>"${errfile}") || exit_code=$?
    else
        ms=$("${bin}" "${size}" "${MAX_ITERS}" "${par}" 2>"${errfile}") || exit_code=$?
    fi

    [[ -s "${errfile}" ]] && cat "${errfile}" >&2
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
# entries format: "impl|binary_path|parallelism"  (parallelism=0 -> serial)
# ---------------------------------------------------------------------------
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
# Summary table with speedup relative to a reference row
# ---------------------------------------------------------------------------
print_summary() {
    local suite="$1" ref_impl="$2" ref_par="$3"
    local csv="${RESULTS_DIR}/data_${suite}.csv"
    local summary="${RESULTS_DIR}/summary_${suite}.txt"
    local tmpavg="${RESULTS_DIR}/.avgs_${suite}.tmp"

    awk -F',' '
    NR==1 { next }
    {
        key = $2 SUBSEP $3 SUBSEP $4
        sum[key] += $6; cnt[key]++
    }
    END {
        for (k in sum) {
            split(k, a, SUBSEP)
            printf "%s|%s|%s|%.3f\n", a[1], a[2], a[3], sum[k]/cnt[k]
        }
    }' "${csv}" | sort -t'|' -k1,1 -k2,2n -k3,3n > "${tmpavg}"

    declare -A REF_AVG
    while IFS='|' read -r impl par size avg; do
        [[ "${impl}" == "${ref_impl}" && "${par}" == "${ref_par}" ]] \
            && REF_AVG["${size}"]="${avg}"
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
        echo "Reference   : ${ref_impl} (par=${ref_par})"
        echo ""
        echo "Average wall time (ms)"
        printf '%0.s=' {1..90}; echo ""
        printf "%-22s" "Impl (parallelism)"
        for size in "${GRID_SIZES[@]}"; do printf "  %10s" "n=${size}"; done
        printf "  %10s\n" "Avg Speedup"
        printf "%-22s" "----------------------"
        for size in "${GRID_SIZES[@]}"; do printf "  %10s" "----------"; done
        printf "  %10s\n" "----------"

        declare -A ROW_AVG ROW_ORDER
        while IFS='|' read -r impl par size avg; do
            local key="${impl}|${par}"
            ROW_AVG["${key}:${size}"]="${avg}"
            ROW_ORDER["${key}"]="${impl}|${par}"
        done < "${tmpavg}"

        IFS=$'\n' sorted_keys=($(printf '%s\n' "${!ROW_ORDER[@]}" \
            | awk -F'|' '{
                if      ($1=="serial_std")   o=0
                else if ($1=="serial_opt")   o=1
                else if ($1=="serial_cache") o=2
                else if ($1=="threads")      o=3
                else                         o=4
                print o"|"$2"|"$0 }' \
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
                if [[ -z "${avg}" ]]; then printf "  %10s" "N/A"; continue; fi
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
        echo "Speedup = T(${ref_impl}) / T(row)  [>1 means faster than reference]"
        printf '%0.s=' {1..90}; echo ""
    } | tee "${summary}"

    rm -f "${tmpavg}"
    log_ok "Summary : ${summary}"
    log_ok "Raw data: ${csv}"
}

# ---------------------------------------------------------------------------
# Suites
# ---------------------------------------------------------------------------
run_suite_serial() {
    local entries=(
        "serial_std|./bin/serial_std|0"
    )
    measure_entries "serial" "${entries[@]}"
    print_summary   "serial" "serial_std" "0"
}

run_suite_compiler() {
    local entries=(
        "serial_opt|./bin/serial_opt|0"
    )
    measure_entries "compiler" "${entries[@]}"
    print_summary   "compiler" "serial_std" "0"
}

run_suite_cache() {
    local entries=(
        "serial_cache|./bin/serial_cache|0"
    )
    measure_entries "cache" "${entries[@]}"
    print_summary   "cache" "serial_std" "0"
}

run_suite_parallel() {
    local entries=("")
    for p in "${PARALLEL_COUNTS[@]}"; do
        entries+=("threads|./bin/threads|${p}")
    done
    for p in "${PARALLEL_COUNTS[@]}"; do
        entries+=("processes|./bin/processes|${p}")
    done
    measure_entries "parallel" "${entries[@]}"
    print_summary   "parallel" "serial_std" "0"
}

# ---------------------------------------------------------------------------
print_banner() {
    echo -e "${BOLD}"
    echo "================================================================"
    echo "   Poisson 1D Jacobi -- Benchmark"
    echo "   Grid sizes   : ${GRID_SIZES[*]}"
    echo "   Max iters    : ${MAX_ITERS}"
    echo "   Repetitions  : ${REPETITIONS}"
    echo "   Parallelism  : ${PARALLEL_COUNTS[*]}"
    echo "   Date         : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================"
    echo -e "${RESET}"
}

# ---------------------------------------------------------------------------
main() {
    local suite="${1:-all}"
    cd "${SCRIPT_DIR}"
    mkdir -p "${RESULTS_DIR}"

    check_and_compile

    trap restore_system EXIT
    optimize_system

    print_banner

    case "${suite}" in
        serial)   run_suite_serial   ;;
        compiler) run_suite_compiler ;;
        cache)    run_suite_cache    ;;
        parallel) run_suite_parallel ;;
        all)
            run_suite_serial
            run_suite_compiler
            run_suite_cache
            run_suite_parallel
            ;;
        *)
            log_error "Unknown suite: '${suite}'"
            log_error "Options: serial | compiler | cache | parallel | all"
            exit 1
            ;;
    esac
}

main "$@"