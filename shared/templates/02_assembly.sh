#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_assembly
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --mem={{MEMORY}}
#SBATCH --output=metaglens_results/reports/logs/02_assembly_%j.log

set -euo pipefail

# ===== Load pipeline utilities =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "${SCRIPT_DIR}/pipeline_utils.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/pipeline_utils.sh is required." >&2
    exit 1
fi
source "${SCRIPT_DIR}/pipeline_utils.sh"

# ===== Parameters =====
STEP_NAME="02_assembly"
WORK_DIR="{{WORK_DIR}}"
CONDA_ENV="{{CONDA_ENV}}"
THREADS={{THREADS}}
ASSEMBLER="{{ASSEMBLER}}"
KMER_LIST="{{KMER_LIST}}"
MIN_CONTIG_LEN={{MIN_CONTIG_LEN}}
ASSEMBLY_STRATEGY="{{ASSEMBLY_STRATEGY}}"
MEGAHIT_PRESET="{{MEGAHIT_PRESET}}"
SAMPLES=({{SAMPLE_LIST}})

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
QC_DIR="${RESULTS_DIR}/01_qc"
OUTPUT_DIR="${RESULTS_DIR}/02_assembly"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
LOG_FILE="${LOG_DIR}/02_assembly.log"

# ===== Activate the Conda environment when available=====
if [[ -n "${CONDA_ENV}" && "${CONDA_ENV}" != "none" ]] && command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)"
    conda activate "${CONDA_ENV}" || log "WARNING: failed to activate env '${CONDA_ENV}', assuming tools on PATH."
fi

# ===== Resume and status checks =====
log_step "MetaGLens Assembly — 02_assembly.sh"
init_status_if_missing

if ! check_step_completed "${STEP_NAME}"; then
    log "Skipping assembly (already completed)."
    exit 0
fi

check_prerequisite "01_qc"
update_step_status "${STEP_NAME}" "running"
enable_step_failure_trap

# ===== Execution =====
log_step "Starting assembly"
log "Assembler: ${ASSEMBLER}"
log "Strategy: ${ASSEMBLY_STRATEGY}"
log "K-mer list: ${KMER_LIST}"
log "Min contig length: ${MIN_CONTIG_LEN} bp"
log "Threads: ${THREADS}"
mkdir -p "${OUTPUT_DIR}"

START_TIME=$(date '+%H:%M')

if [[ "${ASSEMBLY_STRATEGY}" == "co-assembly" ]]; then
    # Co-assembly: combine reads from all samples
    log_step "Co-assembly mode — combining all samples"
    R1_LIST=$(printf "${QC_DIR}/%s_clean_R1.fastq.gz," "${SAMPLES[@]}")
    R2_LIST=$(printf "${QC_DIR}/%s_clean_R2.fastq.gz," "${SAMPLES[@]}")
    R1_LIST="${R1_LIST%,}"
    R2_LIST="${R2_LIST%,}"
    SAMPLE_NAME="coassembly"

    if [[ "${ASSEMBLER}" == "megahit" ]]; then
        log "Running MEGAHIT..."
        megahit -1 "${R1_LIST}" -2 "${R2_LIST}" \
            -o "${OUTPUT_DIR}/${SAMPLE_NAME}" \
            --k-list "${KMER_LIST}" \
            --min-contig-len "${MIN_CONTIG_LEN}" \
            --presets "${MEGAHIT_PRESET}" \
            --force \
            -t "${THREADS}"
    else
        log "Running metaSPAdes..."
        metaspades.py -1 "${R1_LIST}" -2 "${R2_LIST}" \
            -o "${OUTPUT_DIR}/${SAMPLE_NAME}" \
            -k "${KMER_LIST}" \
            --threads "${THREADS}"
    fi

    # Filter and summarize contigs; use final.contigs_filtered.fa as the canonical output
    CONTIGS_FILE="${OUTPUT_DIR}/${SAMPLE_NAME}/final.contigs.fa"
    [[ -f "${CONTIGS_FILE}" ]] || CONTIGS_FILE="${OUTPUT_DIR}/${SAMPLE_NAME}/contigs.fasta"

    if [[ -f "${CONTIGS_FILE}" ]]; then
        seqkit seq -m "${MIN_CONTIG_LEN}" "${CONTIGS_FILE}" \
            -o "${OUTPUT_DIR}/${SAMPLE_NAME}/final.contigs_filtered.fa"
        log_step "Assembly stats for ${SAMPLE_NAME}"
        seqkit stats -T "${OUTPUT_DIR}/${SAMPLE_NAME}/final.contigs_filtered.fa"
    fi

else
    # Per-sample assembly
    for SAMPLE in "${SAMPLES[@]}"; do
        log_step "Assembling sample: ${SAMPLE}"
        R1="${QC_DIR}/${SAMPLE}_clean_R1.fastq.gz"
        R2="${QC_DIR}/${SAMPLE}_clean_R2.fastq.gz"

        if [[ "${ASSEMBLER}" == "megahit" ]]; then
            megahit -1 "${R1}" -2 "${R2}" \
                -o "${OUTPUT_DIR}/${SAMPLE}" \
                --k-list "${KMER_LIST}" \
                --min-contig-len "${MIN_CONTIG_LEN}" \
                --presets "${MEGAHIT_PRESET}" \
                --force \
                -t "${THREADS}"
            CONTIGS_FILE="${OUTPUT_DIR}/${SAMPLE}/final.contigs.fa"
        else
            metaspades.py -1 "${R1}" -2 "${R2}" \
                -o "${OUTPUT_DIR}/${SAMPLE}" \
                -k "${KMER_LIST}" \
                --threads "${THREADS}"
            CONTIGS_FILE="${OUTPUT_DIR}/${SAMPLE}/contigs.fasta"
        fi

        # Filter short contigs; use final.contigs_filtered.fa as the canonical output
        if [[ -f "${CONTIGS_FILE}" ]]; then
            seqkit seq -m "${MIN_CONTIG_LEN}" "${CONTIGS_FILE}" \
                -o "${OUTPUT_DIR}/${SAMPLE}/final.contigs_filtered.fa"
            log "  Contig stats for ${SAMPLE}:"
            seqkit stats -T "${OUTPUT_DIR}/${SAMPLE}/final.contigs_filtered.fa"
        fi
    done
fi

# ===== Update status and run log =====
update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"
    cat >> "${RUN_LOG}" << EOFRUNLOGASM

### 02 Assembly (Assembly)
- **Tool**: ${ASSEMBLER}
- **Strategy**: ${ASSEMBLY_STRATEGY}
- **k-mer**: ${KMER_LIST}
- **Minimum contig length**: ${MIN_CONTIG_LEN} bp
- **Output**: ${OUTPUT_DIR}/
- **Detailed log**: logs/02_assembly.log

EOFRUNLOGASM
fi

log_step "Assembly completed"
echo "Next step: bash 03_read_mapping.sh"
