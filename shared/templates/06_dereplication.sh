#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_derep
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --mem={{MEMORY}}
#SBATCH --output=metaglens_results/reports/logs/06_derep_%j.log

set -euo pipefail

# ===== Load pipeline utilities =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "${SCRIPT_DIR}/pipeline_utils.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/pipeline_utils.sh is required." >&2
    exit 1
fi
source "${SCRIPT_DIR}/pipeline_utils.sh"

# ===== Parameters =====
STEP_NAME="06_derep"
WORK_DIR="{{WORK_DIR}}"
BINS_DIR="{{BINS_DIR}}"
CONDA_ENV="{{CONDA_ENV}}"
THREADS={{THREADS}}
ANI_THRESHOLD={{ANI_THRESHOLD}}

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
OUTPUT_DIR="${RESULTS_DIR}/06_derep"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
LOG_FILE="${LOG_DIR}/06_derep.log"

# ===== Activate the Conda environment when available=====
if [[ -n "${CONDA_ENV}" && "${CONDA_ENV}" != "none" ]] && command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)"
    conda activate "${CONDA_ENV}" || log "WARNING: failed to activate env '${CONDA_ENV}', assuming tools on PATH."
fi

# ===== Resume and status checks =====
log_step "MetaGLens Dereplication — 06_dereplication.sh"
init_status_if_missing

if ! check_step_completed "${STEP_NAME}"; then
    log "Skipping dereplication (already completed)."
    exit 0
fi

check_prerequisite "05_checkm"
update_step_status "${STEP_NAME}" "running"
enable_step_failure_trap

# ===== Execution =====
log_step "Starting dereplication with dRep"
log "Input bins: ${BINS_DIR}"
log "ANI threshold: ${ANI_THRESHOLD}%"
log "Threads: ${THREADS}"
mkdir -p "${OUTPUT_DIR}"

START_TIME=$(date '+%H:%M')

# Collect supported genome extensions without relying on a failing glob.
shopt -s nullglob
GENOMES=(
    "${BINS_DIR}"/*.fa
    "${BINS_DIR}"/*.fna
    "${BINS_DIR}"/*.fasta
)
shopt -u nullglob
INPUT_COUNT=${#GENOMES[@]}
log "Input genomes: ${INPUT_COUNT}"

if [[ "${INPUT_COUNT}" -eq 0 ]]; then
    log "ERROR: No bins found in ${BINS_DIR}"
    update_step_status "${STEP_NAME}" "failed"
    exit 1
fi

# Normalize 95 or 0.95 to the 0-1 ANI value required by dRep
SA_THRESHOLD=$(awk "BEGIN {v=${ANI_THRESHOLD}; print (v > 1) ? v/100 : v}")

# Build genomeInfo (genome, completeness, contamination) from the filtered CheckM2 report.
# Avoid an internal CheckM v1 run because this pipeline uses CheckM2
GENOME_INFO="${OUTPUT_DIR}/genomeInfo.csv"
QREPORT="${RESULTS_DIR}/05_checkm/quality_report_filtered.tsv"
if [[ -f "${QREPORT}" ]]; then
    echo "genome,completeness,contamination" > "${GENOME_INFO}"
    while IFS=$'\t' read -r BIN_NAME COMP CONT _; do
        [[ "${BIN_NAME}" == "Name" ]] && continue
        for EXT in fa fasta fna; do
            if [[ -f "${BINS_DIR}/${BIN_NAME}.${EXT}" ]]; then
                echo "${BIN_NAME}.${EXT},${COMP},${CONT}" >> "${GENOME_INFO}"
                break
            fi
        done
    done < "${QREPORT}"
    GENOME_INFO_ARGS=(--genomeInfo "${GENOME_INFO}")
    log "genomeInfo generated from CheckM2 report: ${GENOME_INFO}"
else
    GENOME_INFO_ARGS=(--ignoreGenomeQuality)
    log "WARNING: CheckM2 filtered report not found (${QREPORT}), dRep will ignore genome quality."
fi

# Use -sa for secondary-clustering ANI and retain the default 0.90 primary threshold.
dRep dereplicate \
    "${OUTPUT_DIR}" \
    -g "${GENOMES[@]}" \
    -p "${THREADS}" \
    -sa "${SA_THRESHOLD}" \
    "${GENOME_INFO_ARGS[@]}" \
    --S_algorithm fastANI

# Count representative genomes
REP_DIR="${OUTPUT_DIR}/dereplicated_genomes"
if [[ -d "${REP_DIR}" ]]; then
    OUTPUT_COUNT=$(find "${REP_DIR}" -maxdepth 1 -type f \
        \( -name '*.fa' -o -name '*.fna' -o -name '*.fasta' \) | wc -l)
else
    OUTPUT_COUNT=0
fi
if [[ "${OUTPUT_COUNT}" -eq 0 ]]; then
    log "ERROR: dRep produced no representative genomes in ${REP_DIR}."
    exit 1
fi
log "Representative genomes: ${OUTPUT_COUNT}"
log "Reduction: $((INPUT_COUNT - OUTPUT_COUNT)) genomes removed (ANI >= ${ANI_THRESHOLD}%)"

# ===== Update status and run log =====
update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"
    cat >> "${RUN_LOG}" << EOFRUNLOGDER

### 06 Dereplication (Dereplication)
- **Tool**: dRep (fastANI)
- **ANI Thresholds**: ${ANI_THRESHOLD}%
- **Input genomes**: ${INPUT_COUNT}
- **Representative genomes**: ${OUTPUT_COUNT}
- **Removed genomes**: $((INPUT_COUNT - OUTPUT_COUNT)) / ${INPUT_COUNT}
- **Output**: ${OUTPUT_DIR}/
- **Detailed log**: logs/06_derep.log

EOFRUNLOGDER
fi

log_step "Dereplication completed"
echo "Next step: bash 07_taxonomy.sh"
