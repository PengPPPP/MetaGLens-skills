#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_mapping
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --mem={{MEMORY}}
#SBATCH --output=metaglens_results/reports/logs/03_mapping_%j.log

set -euo pipefail

# ===== Load pipeline utilities =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "${SCRIPT_DIR}/pipeline_utils.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/pipeline_utils.sh is required." >&2
    exit 1
fi
source "${SCRIPT_DIR}/pipeline_utils.sh"

# ===== Parameters =====
STEP_NAME="03_mapping"
WORK_DIR="{{WORK_DIR}}"
CONDA_ENV="{{CONDA_ENV}}"
THREADS={{THREADS}}
ALIGN_TOOL="{{ALIGN_TOOL}}"
ALIGN_MODE="{{ALIGN_MODE}}"
CALC_DEPTH="{{CALC_DEPTH}}"
ASSEMBLY_STRATEGY="{{ASSEMBLY_STRATEGY}}"
SAMPLES=({{SAMPLE_LIST}})

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
QC_DIR="${RESULTS_DIR}/01_qc"
ASSEMBLY_DIR="${RESULTS_DIR}/02_assembly"
OUTPUT_DIR="${RESULTS_DIR}/03_mapping"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
LOG_FILE="${LOG_DIR}/03_mapping.log"

# ===== Activate the Conda environment when available=====
if [[ -n "${CONDA_ENV}" && "${CONDA_ENV}" != "none" ]] && command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)"
    conda activate "${CONDA_ENV}" || log "WARNING: failed to activate env '${CONDA_ENV}', assuming tools on PATH."
fi

# ===== Resume and status checks =====
log_step "MetaGLens Mapping — 03_read_mapping.sh"
init_status_if_missing

if ! check_step_completed "${STEP_NAME}"; then
    log "Skipping mapping (already completed)."
    exit 0
fi

check_prerequisite "02_assembly"
update_step_status "${STEP_NAME}" "running"
enable_step_failure_trap

# ===== Execution =====
log_step "Starting read mapping"
log "Align tool: ${ALIGN_TOOL}"
log "Align mode: ${ALIGN_MODE}"
log "Calculate depth: ${CALC_DEPTH}"
log "Threads: ${THREADS}"
mkdir -p "${OUTPUT_DIR}"

START_TIME=$(date '+%H:%M')

# Resolve contig file locations
if [[ "${ASSEMBLY_STRATEGY}" == "co-assembly" ]]; then
    # Co-assembly uses one contig file
    COASSEMBLY_DIR="${ASSEMBLY_DIR}/coassembly"
    CONTIGS_FILE="${COASSEMBLY_DIR}/final.contigs_filtered.fa"
    [[ -f "${CONTIGS_FILE}" ]] || CONTIGS_FILE="${COASSEMBLY_DIR}/final.contigs.fa"
    [[ -f "${CONTIGS_FILE}" ]] || CONTIGS_FILE="${COASSEMBLY_DIR}/contigs.fasta"
    CONTIGS_MODE="shared"
    log "Co-assembly detected — using shared contigs: ${CONTIGS_FILE}"
else
    CONTIGS_MODE="per_sample"
fi

for SAMPLE in "${SAMPLES[@]}"; do
    log_step "Mapping sample: ${SAMPLE}"
    R1="${QC_DIR}/${SAMPLE}_clean_R1.fastq.gz"
    R2="${QC_DIR}/${SAMPLE}_clean_R2.fastq.gz"

    if [[ "${CONTIGS_MODE}" == "per_sample" ]]; then
        # Per-sample assembly uses one contig file per sample
        CONTIGS_FILE="${ASSEMBLY_DIR}/${SAMPLE}/final.contigs_filtered.fa"
        [[ -f "${CONTIGS_FILE}" ]] || CONTIGS_FILE="${ASSEMBLY_DIR}/${SAMPLE}/final.contigs.fa"
        [[ -f "${CONTIGS_FILE}" ]] || CONTIGS_FILE="${ASSEMBLY_DIR}/${SAMPLE}/contigs.fasta"
    fi

    # Store BAM files in sample subdirectories to match the stage 04 contract
    SAMPLE_DIR="${OUTPUT_DIR}/${SAMPLE}"
    BAM="${SAMPLE_DIR}/${SAMPLE}.sorted.bam"
    mkdir -p "${SAMPLE_DIR}"

    if [[ ! -f "${CONTIGS_FILE}" ]]; then
        log "ERROR: Contigs file not found: ${CONTIGS_FILE}"
        exit 1
    fi
    log "  Contigs: ${CONTIGS_FILE}"

    # Step 1: Build the index
    if [[ "${ALIGN_TOOL}" == "bowtie2" ]]; then
        mkdir -p "${SAMPLE_DIR}"
        INDEX_PREFIX="${SAMPLE_DIR}/${SAMPLE}_contigs_idx"
        log "  Building Bowtie2 index..."
        bowtie2-build --threads "${THREADS}" "${CONTIGS_FILE}" "${INDEX_PREFIX}"

        # Step 2: Align reads
        log "  Running Bowtie2 alignment..."
        bowtie2 --"${ALIGN_MODE}" \
            -x "${INDEX_PREFIX}" \
            -1 "${R1}" -2 "${R2}" \
            --threads "${THREADS}" \
            2>"${SAMPLE_DIR}/${SAMPLE}_bowtie2.log" | \
            samtools sort -@ "${THREADS}" -o "${BAM}"
    else
        # bwa-mem2
        log "  Running bwa-mem2 alignment..."
        bwa-mem2 index "${CONTIGS_FILE}"
        bwa-mem2 mem -t "${THREADS}" "${CONTIGS_FILE}" "${R1}" "${R2}" | \
            samtools sort -@ "${THREADS}" -o "${BAM}"
    fi

    # Step 3: Index the BAM file
    log "  Indexing BAM..."
    samtools index -@ "${THREADS}" "${BAM}"

    # Step 4: Alignment statistics
    TOTAL_READS=$(samtools view -c "${BAM}" 2>/dev/null)
    MAPPED_READS=$(samtools view -c -F 4 "${BAM}" 2>/dev/null)
    log "  Total reads in BAM: ${TOTAL_READS}"
    log "  Mapped reads: ${MAPPED_READS}"

    # Step 5: Optional contig-depth calculation
    if [[ "${CALC_DEPTH}" == "yes" ]]; then
        log "  Calculating contig depth..."
        jgi_summarize_bam_contig_depths \
            --outputDepth "${SAMPLE_DIR}/${SAMPLE}_depth.txt" \
            "${BAM}"
        log "  Depth file: ${SAMPLE_DIR}/${SAMPLE}_depth.txt"
    fi

    log "  Sample ${SAMPLE} mapping completed."
done

# For a co-assembly, create one shared depth table from all sample BAM files.
if [[ "${ASSEMBLY_STRATEGY}" == "co-assembly" && "${CALC_DEPTH}" == "yes" ]]; then
    COASSEMBLY_BAMS=()
    for SAMPLE in "${SAMPLES[@]}"; do
        BAM="${OUTPUT_DIR}/${SAMPLE}/${SAMPLE}.sorted.bam"
        [[ -f "${BAM}" ]] && COASSEMBLY_BAMS+=("${BAM}")
    done
    if [[ ${#COASSEMBLY_BAMS[@]} -eq 0 ]]; then
        log "ERROR: No BAM files are available for co-assembly depth calculation."
        exit 1
    fi
    log "Calculating shared co-assembly depth from ${#COASSEMBLY_BAMS[@]} BAM files..."
    jgi_summarize_bam_contig_depths \
        --outputDepth "${OUTPUT_DIR}/coassembly_depth.txt" \
        "${COASSEMBLY_BAMS[@]}"
    log "Shared depth file: ${OUTPUT_DIR}/coassembly_depth.txt"
fi

# ===== Update status and run log =====
update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"
    cat >> "${RUN_LOG}" << EOFRUNLOGMAP

### 03 Read mapping and abundance (Read Mapping)
- **Tool**: ${ALIGN_TOOL} (${ALIGN_MODE} mode)
- **Mapped samples**: ${#SAMPLES[@]}
- **Contigs Mode**: ${CONTIGS_MODE}
- **Depth calculation**: ${CALC_DEPTH}
- **Output**: ${OUTPUT_DIR}/
- **Detailed log**: logs/03_mapping.log

EOFRUNLOGMAP
fi

log_step "Read mapping completed"
echo "Next step: bash 04_binning.sh"
