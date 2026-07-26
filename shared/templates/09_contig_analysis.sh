#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_contig
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --mem={{MEMORY}}
#SBATCH --output=metaglens_results/reports/logs/09_contig_%j.log

set -euo pipefail

# ===== Load pipeline utilities =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "${SCRIPT_DIR}/pipeline_utils.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/pipeline_utils.sh is required." >&2
    exit 1
fi
source "${SCRIPT_DIR}/pipeline_utils.sh"

# ===== Parameters =====
# Contig-based analysis for workflows that do not reconstruct MAGs:
#   Prodigal gene prediction -> eggNOG-mapper functional annotation
#   + optional contig taxonomy (Kraken2) + contig coverage abundance table.
STEP_NAME="09_contig"
WORK_DIR="{{WORK_DIR}}"
CONDA_ENV="{{CONDA_ENV}}"
THREADS={{THREADS}}
ASSEMBLY_STRATEGY="{{ASSEMBLY_STRATEGY}}"
GROUP_LABEL="{{GROUP_LABEL}}"
USE_EGGNOG="{{USE_EGGNOG}}"
EGGNOG_DB="{{EGGNOG_DB}}"
CONTIG_TAXONOMY="{{CONTIG_TAXONOMY}}"     # kraken2 | none
KRAKEN2_DB="{{KRAKEN2_DB}}"
KRAKEN2_CONFIDENCE={{KRAKEN2_CONFIDENCE}}
SAMPLES=({{SAMPLE_LIST}})

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
ASSEMBLY_DIR="${RESULTS_DIR}/02_assembly"
MAPPING_DIR="${RESULTS_DIR}/03_mapping"
OUTPUT_DIR="${RESULTS_DIR}/09_contig"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
LOG_FILE="${LOG_DIR}/09_contig.log"

# ===== Activate the Conda environment when available =====
if [[ -n "${CONDA_ENV}" && "${CONDA_ENV}" != "none" ]] && command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)"
    conda activate "${CONDA_ENV}" || log "WARNING: failed to activate env '${CONDA_ENV}', assuming tools on PATH."
fi

# ===== Resume and status checks =====
log_step "MetaGLens Contig Analysis — 09_contig_analysis.sh"
init_status_if_missing

if ! check_step_completed "${STEP_NAME}"; then
    log "Skipping contig analysis (already completed)."
    exit 0
fi

check_prerequisite "03_mapping"
update_step_status "${STEP_NAME}" "running"
enable_step_failure_trap

# ===== Parallel plan =====
# Per-sample gene prediction / contig taxonomy support array jobs; the combined
# eggNOG-mapper run is a single job that uses all available threads.
load_parallel_plan
log "Parallel plan: exec_env=${EXEC_ENV}, jobs=${PARALLEL_JOBS}, threads/job=${THREADS_PER_JOB}, total=${TOTAL_THREADS}"

# ===== Resolve contig units =====
# Co-assembly: a single unit labeled GROUP_LABEL. Per-sample: one unit per sample.
if [[ "${ASSEMBLY_STRATEGY}" == "co-assembly" ]]; then
    CONTIG_UNITS=("coassembly")
    SINGLE_CONTIG=true
else
    CONTIG_UNITS=("${SAMPLES[@]}")
    SINGLE_CONTIG=false
fi

mkdir -p "${OUTPUT_DIR}"/{genes,eggnog,taxonomy,abundance}
START_TIME=$(date '+%H:%M')

# Resolve the contig file for a unit.
resolve_unit_contigs() {
    local UNIT="$1"
    local f
    if [[ "${SINGLE_CONTIG}" == true ]]; then
        f="${ASSEMBLY_DIR}/coassembly/final.contigs_filtered.fa"
        [[ -f "${f}" ]] || f="${ASSEMBLY_DIR}/coassembly/final.contigs.fa"
        [[ -f "${f}" ]] || f="${ASSEMBLY_DIR}/coassembly/contigs.fasta"
    else
        f="${ASSEMBLY_DIR}/${UNIT}/final.contigs_filtered.fa"
        [[ -f "${f}" ]] || f="${ASSEMBLY_DIR}/${UNIT}/final.contigs.fa"
        [[ -f "${f}" ]] || f="${ASSEMBLY_DIR}/${UNIT}/contigs.fasta"
    fi
    printf '%s\n' "${f}"
}

unit_label() {
    local UNIT="$1"
    if [[ "${SINGLE_CONTIG}" == true ]]; then printf '%s\n' "${GROUP_LABEL}"; else printf '%s\n' "${UNIT}"; fi
}

# ===== Step 1: Prodigal gene prediction (per unit, parallel) =====
predict_genes() {
    local UNIT="$1"
    local CONTIGS LABEL
    CONTIGS="$(resolve_unit_contigs "${UNIT}")"
    LABEL="$(unit_label "${UNIT}")"
    if [[ ! -f "${CONTIGS}" ]]; then
        log "ERROR: Contigs not found for unit '${UNIT}': ${CONTIGS}"
        return 1
    fi
    log_step "Prodigal gene prediction: ${UNIT} (label: ${LABEL})"
    prodigal -i "${CONTIGS}" \
        -a "${OUTPUT_DIR}/genes/${LABEL}_proteins.faa" \
        -d "${OUTPUT_DIR}/genes/${LABEL}_genes.fna" \
        -f gff -o "${OUTPUT_DIR}/genes/${LABEL}_genes.gff" \
        -p meta
    # Prefix protein IDs with the unit label so combined annotations stay traceable.
    awk -v prefix="${LABEL}" '/^>/{sub(/^>/, ">" prefix "|")} {print}' \
        "${OUTPUT_DIR}/genes/${LABEL}_proteins.faa" \
        > "${OUTPUT_DIR}/genes/${LABEL}_proteins.prefixed.faa"
    local gene_count
    gene_count=$(grep -c ">" "${OUTPUT_DIR}/genes/${LABEL}_proteins.faa" 2>/dev/null) || gene_count=0
    log "  [${UNIT}] predicted genes: ${gene_count}"
    printf '%d\n' "${gene_count}" > "${OUTPUT_DIR}/genes/${LABEL}.genecount"
}

mapfile -t RUN_UNITS < <(resolve_task_samples "${CONTIG_UNITS[@]}")
if [[ ${#RUN_UNITS[@]} -le 1 ]]; then PRED_THREADS="${TOTAL_THREADS}"; else PRED_THREADS="${THREADS_PER_JOB}"; fi
log "Predicting genes for ${#RUN_UNITS[@]} unit(s) with up to ${PARALLEL_JOBS} concurrent job(s)."
run_parallel "${PARALLEL_JOBS}" predict_genes "${RUN_UNITS[@]}"

TOTAL_GENES=0
for UNIT in "${RUN_UNITS[@]}"; do
    LABEL="$(unit_label "${UNIT}")"
    GC_FILE="${OUTPUT_DIR}/genes/${LABEL}.genecount"
    [[ -f "${GC_FILE}" ]] && TOTAL_GENES=$((TOTAL_GENES + $(cat "${GC_FILE}")))
done
log "Total predicted genes: ${TOTAL_GENES}"

# ===== Step 2: eggNOG-mapper functional annotation (combined, single job) =====
ANNOTATED_GENES=0
if [[ "${USE_EGGNOG}" == "yes" ]]; then
    log_step "eggNOG-mapper functional annotation"
    if [[ ! -d "${EGGNOG_DB}" ]]; then
        log "ERROR: eggNOG data directory not found: ${EGGNOG_DB}"
        exit 1
    fi
    cat "${OUTPUT_DIR}"/genes/*_proteins.prefixed.faa > "${OUTPUT_DIR}/eggnog/all_proteins.faa"
    TOTAL_PROTEINS=$(grep -c ">" "${OUTPUT_DIR}/eggnog/all_proteins.faa" 2>/dev/null) || TOTAL_PROTEINS=0
    if [[ "${TOTAL_PROTEINS}" -eq 0 ]]; then
        log "ERROR: No protein sequences are available for eggNOG-mapper."
        exit 1
    fi
    emapper.py \
        -i "${OUTPUT_DIR}/eggnog/all_proteins.faa" \
        --output "eggnog_results" \
        --output_dir "${OUTPUT_DIR}/eggnog" \
        --data_dir "${EGGNOG_DB}" \
        -m diamond \
        --cpu "${TOTAL_THREADS}" \
        --override
    ANNOT_FILE="${OUTPUT_DIR}/eggnog/eggnog_results.emapper.annotations"
    if [[ -f "${ANNOT_FILE}" ]]; then
        ANNOTATED_GENES=$(grep -cv "^#" "${ANNOT_FILE}" 2>/dev/null) || ANNOTATED_GENES=0
        log "  Annotated sequences: ${ANNOTATED_GENES}/${TOTAL_PROTEINS}"
    fi
fi

# ===== Step 3: Contig taxonomy (optional, Kraken2 on contigs, parallel) =====
if [[ "${CONTIG_TAXONOMY}" == "kraken2" ]]; then
    if [[ ! -d "${KRAKEN2_DB}" ]]; then
        log "ERROR: Kraken2 database not found: ${KRAKEN2_DB}"
        exit 1
    fi
    classify_contigs() {
        local UNIT="$1"
        local CONTIGS LABEL
        CONTIGS="$(resolve_unit_contigs "${UNIT}")"
        LABEL="$(unit_label "${UNIT}")"
        log_step "Kraken2 contig taxonomy: ${UNIT}"
        kraken2 --db "${KRAKEN2_DB}" \
            "${CONTIGS}" \
            --output "${OUTPUT_DIR}/taxonomy/${LABEL}_contig_kraken2.out" \
            --report "${OUTPUT_DIR}/taxonomy/${LABEL}_contig_report.txt" \
            --confidence "${KRAKEN2_CONFIDENCE}" \
            --threads "${THREADS_PER_JOB}"
    }
    log "Classifying contigs for ${#RUN_UNITS[@]} unit(s)."
    run_parallel "${PARALLEL_JOBS}" classify_contigs "${RUN_UNITS[@]}"
else
    log "Contig taxonomy disabled (CONTIG_TAXONOMY=${CONTIG_TAXONOMY})."
fi

# ===== Step 4: Contig coverage abundance table =====
# Build a contig x sample mean-coverage matrix from the jgi depth files produced
# by stage 03 (requires CALC_DEPTH=yes). Handles co-assembly (one shared table)
# and per-sample assembly (per-sample depth files).
log_step "Assembling contig coverage abundance table"
ABUND_OUT="${OUTPUT_DIR}/abundance/contig_coverage.tsv"
if [[ "${SINGLE_CONTIG}" == true && -f "${MAPPING_DIR}/coassembly_depth.txt" ]]; then
    # jgi depth: col1=contigName, col2=contigLen, col3=totalAvgDepth, then per-BAM columns.
    cp "${MAPPING_DIR}/coassembly_depth.txt" "${ABUND_OUT}"
    log "Contig coverage table (co-assembly): ${ABUND_OUT}"
else
    # Per-sample: merge each sample's mean depth (col1=contig, col3=avg depth).
    MERGE_INPUTS=()
    for UNIT in "${SAMPLES[@]}"; do
        DF="${MAPPING_DIR}/${UNIT}/${UNIT}_depth.txt"
        [[ -f "${DF}" ]] && MERGE_INPUTS+=("${UNIT}:${DF}")
    done
    if [[ ${#MERGE_INPUTS[@]} -eq 0 ]]; then
        log "WARNING: no per-sample depth files found; skipping coverage table (run stage 03 with CALC_DEPTH=yes)."
    else
        METAGLENS_MERGE_INPUTS="${MERGE_INPUTS[*]}" METAGLENS_ABUND_OUT="${ABUND_OUT}" python3 - <<'PY'
import os
inputs = os.environ["METAGLENS_MERGE_INPUTS"].split()
out = os.environ["METAGLENS_ABUND_OUT"]
cov = {}
samples = []
for token in inputs:
    sample, path = token.split(":", 1)
    samples.append(sample)
    with open(path) as fh:
        header = fh.readline()
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            contig, depth = parts[0], parts[2]
            cov.setdefault(contig, {})[sample] = depth
with open(out, "w") as fh:
    fh.write("contig\t" + "\t".join(samples) + "\n")
    for contig in sorted(cov):
        row = [cov[contig].get(s, "0") for s in samples]
        fh.write(contig + "\t" + "\t".join(row) + "\n")
print("Contig coverage table (per-sample): %s" % out)
PY
        log "Contig coverage table (per-sample merged): ${ABUND_OUT}"
    fi
fi

# ===== Summary =====
log_step "Contig Analysis Summary"
log "Units analyzed        : ${#RUN_UNITS[@]}"
log "Total predicted genes : ${TOTAL_GENES}"
log "eggNOG annotated      : ${ANNOTATED_GENES}"
log "Contig taxonomy       : ${CONTIG_TAXONOMY}"
log "Output directory      : ${OUTPUT_DIR}/"

# ===== Update status and run log =====
update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"
    cat >> "${RUN_LOG}" << EOFRUNLOGCTG

### 09 Contig-based analysis (no binning)
- **Gene prediction**: Prodigal (meta mode)
- **Functional annotation**: eggNOG-mapper=${USE_EGGNOG} (DB: ${EGGNOG_DB})
- **Contig taxonomy**: ${CONTIG_TAXONOMY}
- **Units**: ${#RUN_UNITS[@]}
- **Predicted genes**: ${TOTAL_GENES}
- **eggNOG annotations**: ${ANNOTATED_GENES}
- **Coverage table**: ${OUTPUT_DIR}/abundance/contig_coverage.tsv
- **Output**: ${OUTPUT_DIR}/
- **Detailed log**: logs/09_contig.log

EOFRUNLOGCTG
fi

log_step "Contig-based analysis completed"
echo "Next step: bash 10_community_summary.sh"
