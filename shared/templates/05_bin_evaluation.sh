#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_checkm
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --mem={{MEMORY}}
#SBATCH --output=metaglens_results/reports/logs/05_checkm_%j.log

set -euo pipefail

# ===== Load pipeline utilities =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "${SCRIPT_DIR}/pipeline_utils.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/pipeline_utils.sh is required." >&2
    exit 1
fi
source "${SCRIPT_DIR}/pipeline_utils.sh"

# ===== Parameters =====
STEP_NAME="05_checkm"
WORK_DIR="{{WORK_DIR}}"
# BINS_DIR should point to the collected, renamed bins from stage 04:
#   {WORK_DIR}/metaglens_results/04_binning/all_bins  (files named {label}_bin{N}.fa)
BINS_DIR="{{BINS_DIR}}"
BIN_EXTENSION="{{BIN_EXTENSION}}"
CONDA_ENV="{{CONDA_ENV}}"
THREADS={{THREADS}}
CHECKM2_DB="{{CHECKM2_DB}}"
COMPLETENESS_MIN={{COMPLETENESS_MIN}}
CONTAMINATION_MAX={{CONTAMINATION_MAX}}

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
OUTPUT_DIR="${RESULTS_DIR}/05_checkm"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
LOG_FILE="${LOG_DIR}/05_checkm.log"

# ===== Activate the Conda environment when available=====
if [[ -n "${CONDA_ENV}" && "${CONDA_ENV}" != "none" ]] && command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)"
    conda activate "${CONDA_ENV}" || log "WARNING: failed to activate env '${CONDA_ENV}', assuming tools on PATH."
fi

# ===== Resume and status checks =====
log_step "MetaGLens CheckM2 — 05_bin_evaluation.sh"
init_status_if_missing

if ! check_step_completed "${STEP_NAME}"; then
    log "Skipping bin evaluation (already completed)."
    exit 0
fi

check_prerequisite "04_binning"
update_step_status "${STEP_NAME}" "running"
enable_step_failure_trap

# ===== Execution =====
log_step "Starting bin quality assessment"
log "CheckM2 DB: ${CHECKM2_DB}"
log "Completeness threshold: >= ${COMPLETENESS_MIN}%"
log "Contamination threshold: <= ${CONTAMINATION_MAX}%"
log "Threads: ${THREADS}"
mkdir -p "${OUTPUT_DIR}"

START_TIME=$(date '+%H:%M')

# Step 1: CheckM2 predict
log "Running CheckM2 predict..."
# Pass the validated upstream bin extension explicitly.
checkm2 predict \
    --input "${BINS_DIR}" \
    --extension "${BIN_EXTENSION}" \
    --output-directory "${OUTPUT_DIR}" \
    --database_path "${CHECKM2_DB}" \
    --threads "${THREADS}"

# Step 2: Filter retained bins
# CheckM2 quality_report.tsv column order:
#   1=Name, 2=Completeness, 3=Contamination, 4=Completeness_Model_Used, ...
# Filter: $2 >= COMPLETENESS_MIN (completeness) AND $3 <= CONTAMINATION_MAX (contamination)
log_step "Filtering bins"
log "Criteria: Completeness(col2) >= ${COMPLETENESS_MIN} AND Contamination(col3) <= ${CONTAMINATION_MAX}"
mkdir -p "${OUTPUT_DIR}/filtered_bins"

REPORT="${OUTPUT_DIR}/quality_report.tsv"

if [[ ! -f "${REPORT}" ]]; then
    log "ERROR: quality_report.tsv not found. CheckM2 may have failed."
    update_step_status "${STEP_NAME}" "failed"
    exit 1
fi

# Use the validated column indexes：$2=Completeness, $3=Contamination
awk -F'\t' -v comp="${COMPLETENESS_MIN}" -v cont="${CONTAMINATION_MAX}" \
    'NR==1 || ($2 >= comp && $3 <= cont)' "${REPORT}" \
    > "${OUTPUT_DIR}/quality_report_filtered.tsv"

# Copy retained bins
while IFS=$'\t' read -r BIN_NAME _; do
    if [[ "${BIN_NAME}" == "Name" ]]; then continue; fi
    for EXT in "${BIN_EXTENSION}" fa fna fasta; do
        if [[ -f "${BINS_DIR}/${BIN_NAME}.${EXT}" ]]; then
            cp "${BINS_DIR}/${BIN_NAME}.${EXT}" "${OUTPUT_DIR}/filtered_bins/"
            break
        fi
    done
done < "${OUTPUT_DIR}/quality_report_filtered.tsv"

NUM_TOTAL=$(tail -n +2 "${REPORT}" 2>/dev/null | wc -l)
NUM_FILTERED=$(tail -n +2 "${OUTPUT_DIR}/quality_report_filtered.tsv" 2>/dev/null | wc -l)
PASS_RATE="N/A"
COMP_MIN="N/A"
COMP_MAX="N/A"
COMP_MEDIAN="N/A"
CONT_MIN="N/A"
CONT_MAX="N/A"

# Quality statistics using validated columns
if [[ "${NUM_TOTAL}" -gt 0 ]]; then
    log_step "Quality Statistics"
    log "Total bins          : ${NUM_TOTAL}"
    log "Passed QC bins      : ${NUM_FILTERED}"
    PASS_RATE=$(awk "BEGIN {printf \"%.1f\", 100*${NUM_FILTERED}/${NUM_TOTAL}}")
    log "Pass rate           : ${PASS_RATE}%"

    # Completeness distribution
    COMP_VALUES=$(tail -n +2 "${REPORT}" | cut -f2 | sort -n)
    COMP_MIN=$(echo "${COMP_VALUES}" | head -1)
    COMP_MAX=$(echo "${COMP_VALUES}" | tail -1)
    N_HALF=$(echo "${COMP_VALUES}" | wc -l)
    N_MIDDLE=$((N_HALF / 2))
    if (( N_HALF % 2 == 0 )); then
        COMP_MEDIAN=$(echo "${COMP_VALUES}" | awk -v n="${N_MIDDLE}" 'NR==n || NR==n+1 {sum+=$1; c++} END{printf "%.2f", sum/c}')
    else
        COMP_MEDIAN=$(echo "${COMP_VALUES}" | awk -v n="$((N_MIDDLE + 1))" 'NR==n {printf "%.2f", $1}')
    fi

    # Contamination distribution
    CONT_VALUES=$(tail -n +2 "${REPORT}" | cut -f3 | sort -n)
    CONT_MIN=$(echo "${CONT_VALUES}" | head -1)
    CONT_MAX=$(echo "${CONT_VALUES}" | tail -1)

    log "Completeness range  : ${COMP_MIN}% - ${COMP_MAX}% (median: ${COMP_MEDIAN}%)"
    log "Contamination range : ${CONT_MIN}% - ${CONT_MAX}%"
fi

# ===== Update status and run log =====
update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"
    cat >> "${RUN_LOG}" << EOFRUNLOGCHK

### 05 MAG quality assessment (CheckM2)
- **Database**: ${CHECKM2_DB}
- **Thresholds**: Completeness >= ${COMPLETENESS_MIN}%, Contamination <= ${CONTAMINATION_MAX}%
- **Total bins**: ${NUM_TOTAL}
- **Retained bins**: ${NUM_FILTERED}
- **Pass rate**: ${PASS_RATE}%
- **Completeness range**: ${COMP_MIN}% - ${COMP_MAX}%
- **Contamination range**: ${CONT_MIN}% - ${CONT_MAX}%
- **Output**: ${OUTPUT_DIR}/
- **Detailed log**: logs/05_checkm.log

EOFRUNLOGCHK
fi

log_step "Bin quality assessment completed"
echo "Next step: bash 06_dereplication.sh"
