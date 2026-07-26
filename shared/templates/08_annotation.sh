#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_annotation
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --mem={{MEMORY}}
#SBATCH --output=metaglens_results/reports/logs/08_annotation_%j.log

set -euo pipefail

# ===== Load pipeline utilities =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "${SCRIPT_DIR}/pipeline_utils.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/pipeline_utils.sh is required." >&2
    exit 1
fi
source "${SCRIPT_DIR}/pipeline_utils.sh"

# ===== Parameters =====
STEP_NAME="08_annotation"
WORK_DIR="{{WORK_DIR}}"
MAGS_DIR="{{MAGS_DIR}}"
CONDA_ENV="{{CONDA_ENV}}"
THREADS={{THREADS}}
USE_PROKKA="{{USE_PROKKA}}"
PROKKA_KINGDOM="{{PROKKA_KINGDOM}}"
USE_EGGNOG="{{USE_EGGNOG}}"
EGGNOG_DB="{{EGGNOG_DB}}"

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
OUTPUT_DIR="${RESULTS_DIR}/08_annotation"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
LOG_FILE="${LOG_DIR}/08_annotation.log"

# ===== Activate the Conda environment when available=====
if [[ -n "${CONDA_ENV}" && "${CONDA_ENV}" != "none" ]] && command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)"
    conda activate "${CONDA_ENV}" || log "WARNING: failed to activate env '${CONDA_ENV}', assuming tools on PATH."
fi

# ===== Resume and status checks =====
log_step "MetaGLens Annotation — 08_annotation.sh"
init_status_if_missing

if ! check_step_completed "${STEP_NAME}"; then
    log "Skipping annotation (already completed)."
    exit 0
fi

check_prerequisite "07_taxonomy"
update_step_status "${STEP_NAME}" "running"
enable_step_failure_trap

# ===== Execution =====
log_step "Starting functional annotation"
log "Prokka: ${USE_PROKKA}"
log "eggNOG-mapper: ${USE_EGGNOG}"
log "Threads: ${THREADS}"
mkdir -p "${OUTPUT_DIR}"

START_TIME=$(date '+%H:%M')

shopt -s nullglob
MAGS=(
    "${MAGS_DIR}"/*.fa
    "${MAGS_DIR}"/*.fna
    "${MAGS_DIR}"/*.fasta
)
shopt -u nullglob
MAG_COUNT=${#MAGS[@]}
log "MAGs to annotate: ${MAG_COUNT}"
TOTAL_GENES=0
ANNOTATED_GENES=0

if [[ "${MAG_COUNT}" -eq 0 ]]; then
    log "ERROR: No MAG files were found in ${MAGS_DIR}."
    exit 1
fi
if [[ "${USE_PROKKA}" != "yes" && "${USE_EGGNOG}" != "yes" ]]; then
    log "ERROR: Enable at least one annotation workflow."
    exit 1
fi

# Prokka annotation
if [[ "${USE_PROKKA}" == "yes" ]]; then
    log_step "Running Prokka"
    mkdir -p "${OUTPUT_DIR}/prokka"

    for MAG in "${MAGS[@]}"; do
        MAG_NAME=$(basename "${MAG}" | sed 's/\.[^.]*$//')
        log "  Annotating: ${MAG_NAME}"

        prokka \
            --kingdom "${PROKKA_KINGDOM}" \
            --metagenome \
            --outdir "${OUTPUT_DIR}/prokka/${MAG_NAME}" \
            --prefix "${MAG_NAME}" \
            --cpus "${THREADS}" \
            --force \
            "${MAG}"

        # Count predicted genes
        GENE_COUNT=$(grep -c ">" "${OUTPUT_DIR}/prokka/${MAG_NAME}/${MAG_NAME}.faa" 2>/dev/null) || GENE_COUNT=0
        TOTAL_GENES=$((TOTAL_GENES + GENE_COUNT))
        log "    Predicted genes: ${GENE_COUNT}"
    done

    log "Prokka annotation completed — total genes: ${TOTAL_GENES}"
fi

# eggNOG-mapper annotation
if [[ "${USE_EGGNOG}" == "yes" ]]; then
    log_step "Running eggNOG-mapper"
    mkdir -p "${OUTPUT_DIR}/eggnog"
    if [[ ! -d "${EGGNOG_DB}" ]]; then
        log "ERROR: eggNOG data directory not found: ${EGGNOG_DB}"
        exit 1
    fi

    # Combine proteins from all MAGs when Prokka has run
    if [[ "${USE_PROKKA}" == "yes" ]]; then
        log "  Collecting Prokka-predicted proteins..."
        cat "${OUTPUT_DIR}"/prokka/*/*.faa > "${OUTPUT_DIR}/eggnog/all_proteins.faa"
    else
        # Predict genes directly with Prodigal
        log "  Running Prodigal for gene prediction..."
        for MAG in "${MAGS[@]}"; do
            MAG_NAME=$(basename "${MAG}" | sed 's/\.[^.]*$//')
            prodigal -i "${MAG}" \
                -a "${OUTPUT_DIR}/eggnog/${MAG_NAME}_proteins.faa" \
                -p meta -f gff \
                -o "${OUTPUT_DIR}/eggnog/${MAG_NAME}_genes.gff"
            awk -v prefix="${MAG_NAME}" \
                '/^>/{sub(/^>/, ">" prefix "|")} {print}' \
                "${OUTPUT_DIR}/eggnog/${MAG_NAME}_proteins.faa" \
                > "${OUTPUT_DIR}/eggnog/${MAG_NAME}_proteins.prefixed.faa"
        done
        cat "${OUTPUT_DIR}"/eggnog/*_proteins.prefixed.faa > "${OUTPUT_DIR}/eggnog/all_proteins.faa"
    fi

    TOTAL_PROTEINS=$(grep -c ">" "${OUTPUT_DIR}/eggnog/all_proteins.faa" 2>/dev/null) || TOTAL_PROTEINS=0
    if [[ "${TOTAL_PROTEINS}" -eq 0 ]]; then
        log "ERROR: No protein sequences are available for eggNOG-mapper."
        exit 1
    fi
    if [[ "${USE_PROKKA}" != "yes" ]]; then
        TOTAL_GENES="${TOTAL_PROTEINS}"
    fi
    log "  Total protein sequences: ${TOTAL_PROTEINS}"

    # eggNOG-mapper
    log "  Running emapper.py..."
    emapper.py \
        -i "${OUTPUT_DIR}/eggnog/all_proteins.faa" \
        --output "eggnog_results" \
        --output_dir "${OUTPUT_DIR}/eggnog" \
        --data_dir "${EGGNOG_DB}" \
        -m diamond \
        --cpu "${THREADS}" \
        --override

    # Annotation statistics
    ANNOT_FILE="${OUTPUT_DIR}/eggnog/eggnog_results.emapper.annotations"
    if [[ -f "${ANNOT_FILE}" ]]; then
        ANNOTATED_GENES=$(grep -cv "^#" "${ANNOT_FILE}" 2>/dev/null) || ANNOTATED_GENES=0
        log "  Annotated sequences: ${ANNOTATED_GENES}/${TOTAL_PROTEINS}"
        if [[ "${TOTAL_PROTEINS}" -gt 0 ]]; then
            log "  Annotation rate: $(awk "BEGIN {printf \"%.1f\", 100*${ANNOTATED_GENES}/${TOTAL_PROTEINS}}")%"
        fi
    fi

    log "eggNOG-mapper annotation completed."
fi

# ===== Update status and run log =====
log_step "Annotation Summary"
log "Total MAGs annotated: ${MAG_COUNT}"
log "Total predicted genes: ${TOTAL_GENES}"
log "eggNOG annotated: ${ANNOTATED_GENES}"

update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"
    cat >> "${RUN_LOG}" << EOFRUNLOGANN

### 08 Functional annotation (Functional Annotation)
- **Prokka**: ${USE_PROKKA}
- **eggNOG-mapper**: ${USE_EGGNOG} (DB: ${EGGNOG_DB})
- **MAGs**: ${MAG_COUNT}
- **Predicted genes**: ${TOTAL_GENES}
- **eggNOG annotations**: ${ANNOTATED_GENES}
- **Output**: ${OUTPUT_DIR}/
- **Detailed log**: logs/08_annotation.log

EOFRUNLOGANN
fi

log_step "Functional annotation completed"
echo ""
echo "MAG functional annotation complete."
echo "Depending on the route, next run: bash 10_community_summary.sh (then 11_delivery.sh)."
echo "View full run log: cat ${RUN_LOG}"
echo "Check tool versions: cat ${REPORTS_DIR}/tool_versions.txt"
echo ""
