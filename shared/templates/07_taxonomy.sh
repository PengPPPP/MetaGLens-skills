#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_taxonomy
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --mem={{MEMORY}}
#SBATCH --output=metaglens_results/reports/logs/07_taxonomy_%j.log

set -euo pipefail

# ===== Load pipeline utilities =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "${SCRIPT_DIR}/pipeline_utils.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/pipeline_utils.sh is required." >&2
    exit 1
fi
source "${SCRIPT_DIR}/pipeline_utils.sh"

# ===== Parameters =====
STEP_NAME="07_taxonomy"
WORK_DIR="{{WORK_DIR}}"
INPUT_PATH="{{INPUT_PATH}}"
CONDA_ENV="{{CONDA_ENV}}"
THREADS={{THREADS}}
TAXONOMY_TOOL="{{TAXONOMY_TOOL}}"
DATABASE_PATH="{{DATABASE_PATH}}"
MAG_EXTENSION="{{MAG_EXTENSION}}"
KRAKEN2_CONFIDENCE={{KRAKEN2_CONFIDENCE}}
USE_BRACKEN="{{USE_BRACKEN}}"
BRACKEN_READ_LENGTH={{BRACKEN_READ_LENGTH}}
SAMPLES=({{SAMPLE_LIST}})

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
OUTPUT_DIR="${RESULTS_DIR}/07_taxonomy"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
LOG_FILE="${LOG_DIR}/07_taxonomy.log"

# ===== Activate the Conda environment when available=====
if [[ -n "${CONDA_ENV}" && "${CONDA_ENV}" != "none" ]] && command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)"
    conda activate "${CONDA_ENV}" || log "WARNING: failed to activate env '${CONDA_ENV}', assuming tools on PATH."
fi

# ===== Resume and status checks =====
log_step "MetaGLens Taxonomy — 07_taxonomy.sh"
init_status_if_missing

if ! check_step_completed "${STEP_NAME}"; then
    log "Skipping taxonomy (already completed)."
    exit 0
fi

check_prerequisite "06_derep"
update_step_status "${STEP_NAME}" "running"
enable_step_failure_trap

# ===== Execution =====
log_step "Starting taxonomic classification"
log "Tool: ${TAXONOMY_TOOL}"
log "Database: ${DATABASE_PATH}"
log "Threads: ${THREADS}"
mkdir -p "${OUTPUT_DIR}"

START_TIME=$(date '+%H:%M')

if [[ "${TAXONOMY_TOOL}" == "gtdbtk" ]]; then
    # GTDB-Tk: classify MAGs
    # GTDB-Tk resolves its reference database through GTDBTK_DATA_PATH
    export GTDBTK_DATA_PATH="${DATABASE_PATH}"
    log "Running GTDB-Tk classify_wf (GTDBTK_DATA_PATH=${GTDBTK_DATA_PATH})..."
    # Pass the validated genome extension explicitly.
    gtdbtk classify_wf \
        --genome_dir "${INPUT_PATH}" \
        --out_dir "${OUTPUT_DIR}/gtdbtk" \
        --extension "${MAG_EXTENSION}" \
        --cpus "${THREADS}" \
        --pplacer_cpus "${THREADS}"

    TOTAL_MAGS=0
    CLASSIFIED=0
    for SUMMARY_FILE in \
        "${OUTPUT_DIR}/gtdbtk/gtdbtk.bac120.summary.tsv" \
        "${OUTPUT_DIR}/gtdbtk/gtdbtk.ar53.summary.tsv"; do
        [[ -f "${SUMMARY_FILE}" ]] || continue
        FILE_TOTAL=$(tail -n +2 "${SUMMARY_FILE}" | wc -l)
        FILE_CLASSIFIED=$(tail -n +2 "${SUMMARY_FILE}" | awk -F'\t' '$2 != "" {n++} END {print n+0}')
        TOTAL_MAGS=$((TOTAL_MAGS + FILE_TOTAL))
        CLASSIFIED=$((CLASSIFIED + FILE_CLASSIFIED))
    done
    log "Total MAGs       : ${TOTAL_MAGS}"
    log "Classified       : ${CLASSIFIED}"
    if [[ "${TOTAL_MAGS}" -gt 0 ]]; then
        CLASSIFICATION_RATE=$(awk "BEGIN {printf \"%.1f\", 100*${CLASSIFIED}/${TOTAL_MAGS}}")
        log "Classification rate: ${CLASSIFICATION_RATE}%"
    else
        log "WARNING: No GTDB-Tk summary rows were found."
    fi

elif [[ "${TAXONOMY_TOOL}" == "kraken2" ]]; then
    # Kraken2: classify reads
    QC_DIR="${RESULTS_DIR}/01_qc"
    mkdir -p "${OUTPUT_DIR}/kraken2"

    for SAMPLE in "${SAMPLES[@]}"; do
        log_step "Classifying sample: ${SAMPLE}"
        R1="${QC_DIR}/${SAMPLE}_clean_R1.fastq.gz"
        R2="${QC_DIR}/${SAMPLE}_clean_R2.fastq.gz"

        kraken2 \
            --db "${DATABASE_PATH}" \
            --paired "${R1}" "${R2}" \
            --output "${OUTPUT_DIR}/kraken2/${SAMPLE}_kraken2.out" \
            --report "${OUTPUT_DIR}/kraken2/${SAMPLE}_report.txt" \
            --confidence "${KRAKEN2_CONFIDENCE}" \
            --threads "${THREADS}" \
            --gzip-compressed

        # Optional Bracken abundance estimation
        if [[ "${USE_BRACKEN}" == "yes" ]]; then
            log "  Running Bracken for ${SAMPLE}..."
            bracken \
                -d "${DATABASE_PATH}" \
                -i "${OUTPUT_DIR}/kraken2/${SAMPLE}_report.txt" \
                -o "${OUTPUT_DIR}/kraken2/${SAMPLE}_bracken.out" \
                -r "${BRACKEN_READ_LENGTH}" -l S
        fi

        # Classification counts from C/U records in Kraken2 output
        KRAKEN_OUT="${OUTPUT_DIR}/kraken2/${SAMPLE}_kraken2.out"
        CLASSIFIED_READS=0
        UNCLASSIFIED_READS=0
        if [[ -f "${KRAKEN_OUT}" ]]; then
            CLASSIFIED_READS=$(awk '$1=="C" {c++} END {print c+0}' "${KRAKEN_OUT}")
            UNCLASSIFIED_READS=$(awk '$1=="U" {c++} END {print c+0}' "${KRAKEN_OUT}")
        fi
        log "  Classified reads: ${CLASSIFIED_READS}"
        log "  Unclassified: ${UNCLASSIFIED_READS}"
    done
fi

# ===== Update status and run log =====
update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"

    if [[ "${TAXONOMY_TOOL}" == "gtdbtk" ]]; then
        cat >> "${RUN_LOG}" << EOFRUNLOGTX

### 07 Taxonomic classification (Taxonomy — GTDB-Tk)
- **Tool**: GTDB-Tk classify_wf
- **Input MAGs**: ${TOTAL_MAGS}
- **Classified**: ${CLASSIFIED}
- **Output**: ${OUTPUT_DIR}/gtdbtk/
- **Detailed log**: logs/07_taxonomy.log

EOFRUNLOGTX
    else
        cat >> "${RUN_LOG}" << EOFRUNLOGTX2

### 07 Taxonomic classification (Taxonomy — Kraken2)
- **Tool**: Kraken2 + Bracken=${USE_BRACKEN}
- **Database**: ${DATABASE_PATH}
- **Samples**: ${#SAMPLES[@]}
- **Output**: ${OUTPUT_DIR}/kraken2/
- **Detailed log**: logs/07_taxonomy.log

EOFRUNLOGTX2
    fi
fi

log_step "Taxonomic classification completed"
echo "Next step: bash 08_annotation.sh"
