#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_qc
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --mem={{MEMORY}}
#SBATCH --output=metaglens_results/reports/logs/01_qc_%j.log

set -euo pipefail

# ===== Load pipeline utilities =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "${SCRIPT_DIR}/pipeline_utils.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/pipeline_utils.sh is required." >&2
    exit 1
fi
source "${SCRIPT_DIR}/pipeline_utils.sh"

# ===== Parameters =====
STEP_NAME="01_qc"
WORK_DIR="{{WORK_DIR}}"
RAW_DATA_DIR="{{RAW_DATA_DIR}}"
CONDA_ENV="{{CONDA_ENV}}"
THREADS={{THREADS}}
QUALITY_THRESHOLD={{QUALITY_THRESHOLD}}
MIN_LENGTH={{MIN_LENGTH}}
REMOVE_HOST="{{REMOVE_HOST}}"
HOST_GENOME="{{HOST_GENOME}}"
REMOVE_PHIX="{{REMOVE_PHIX}}"
PHIX_INDEX="{{PHIX_INDEX}}"
SAMPLE_MANIFEST="{{SAMPLE_MANIFEST}}"
SAMPLES=()

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
OUTPUT_DIR="${RESULTS_DIR}/01_qc"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
LOG_FILE="${LOG_DIR}/01_qc.log"

# ===== Activate the Conda environment when available=====
if [[ -n "${CONDA_ENV}" && "${CONDA_ENV}" != "none" ]] && command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)"
    conda activate "${CONDA_ENV}" || log "WARNING: failed to activate env '${CONDA_ENV}', assuming tools on PATH."
fi

# ===== Resume and status checks =====
log_step "MetaGLens QC — 01_quality_control.sh"
init_status_if_missing

if ! check_step_completed "${STEP_NAME}"; then
    log "Skipping QC (already completed)."
    exit 0
fi

check_prerequisite "00_setup"

update_step_status "${STEP_NAME}" "running"
enable_step_failure_trap

# ===== Parallel plan =====
# Per-sample stages support scheduler array jobs: when submitted with
# --array=1-<num_samples> (SLURM) or -t 1-<num_samples> (SGE), each task
# processes a single sample selected via resolve_task_samples.
load_parallel_plan
log "Parallel plan: exec_env=${EXEC_ENV}, jobs=${PARALLEL_JOBS}, threads/job=${THREADS_PER_JOB}, total=${TOTAL_THREADS}"

# ===== Execution =====
log_step "Starting quality control"
log "Quality threshold: Q${QUALITY_THRESHOLD}"
log "Min read length: ${MIN_LENGTH} bp"
mkdir -p "${OUTPUT_DIR}"

START_TIME=$(date '+%H:%M')

if [[ "${REMOVE_HOST}" == "yes" ]]; then
    log "Host removal enabled — reference: ${HOST_GENOME}"
fi
if [[ "${REMOVE_PHIX}" == "yes" ]]; then
    log "PhiX removal enabled"
fi

TOTAL_BEFORE=0
TOTAL_AFTER=0

count_fastq_reads() {
    local fastq="$1"
    if [[ "${fastq}" == *.gz ]]; then
        gzip -cd -- "${fastq}" | awk 'END{printf "%d", NR/4}'
    else
        awk 'END{printf "%d", NR/4}' "${fastq}"
    fi
}

if [[ ! -r "${SAMPLE_MANIFEST}" ]]; then
    log "ERROR: Sample manifest is not readable: ${SAMPLE_MANIFEST}"
    exit 1
fi

# Prepare host/PhiX references: build a Bowtie2 index from FASTA input, otherwise treat the value as an index prefix
HOST_INDEX=""
if [[ "${REMOVE_HOST}" == "yes" ]]; then
    if [[ "${HOST_GENOME}" =~ \.(fa|fasta|fna)(\.gz)?$ ]]; then
        mkdir -p "${OUTPUT_DIR}/host_index"
        HOST_INDEX="${OUTPUT_DIR}/host_index/host"
        log "Building Bowtie2 index for host genome: ${HOST_GENOME}"
        bowtie2-build --threads "${TOTAL_THREADS}" "${HOST_GENOME}" "${HOST_INDEX}"
    else
        HOST_INDEX="${HOST_GENOME}"
    fi
fi
PHIX_REF_INDEX=""
if [[ "${REMOVE_PHIX}" == "yes" ]]; then
    if [[ "${PHIX_INDEX}" =~ \.(fa|fasta|fna)(\.gz)?$ ]]; then
        mkdir -p "${OUTPUT_DIR}/phix_index"
        PHIX_REF_INDEX="${OUTPUT_DIR}/phix_index/phix"
        log "Building Bowtie2 index for PhiX: ${PHIX_INDEX}"
        bowtie2-build --threads "${TOTAL_THREADS}" "${PHIX_INDEX}" "${PHIX_REF_INDEX}"
    else
        PHIX_REF_INDEX="${PHIX_INDEX}"
    fi
fi

# Read the manifest into sample arrays so samples can be processed concurrently.
declare -a SAMPLES=()
declare -A R1_OF=()
declare -A R2_OF=()
while IFS=$'\t' read -r SAMPLE R1 R2; do
    [[ -n "${SAMPLE}" ]] || continue
    [[ "${SAMPLE}" == "sample_id" ]] && continue
    SAMPLES+=("${SAMPLE}")
    R1_OF["${SAMPLE}"]="${R1}"
    R2_OF["${SAMPLE}"]="${R2}"
done < "${SAMPLE_MANIFEST}"

if [[ ${#SAMPLES[@]} -eq 0 ]]; then
    log "ERROR: The sample manifest contains no data rows."
    exit 1
fi

# Per-sample QC. Writes "<before>\t<after>" to a per-sample stats file so the
# main process can aggregate totals after concurrent execution.
process_qc_sample() {
    local SAMPLE="$1"
    local R1="${R1_OF[$SAMPLE]}"
    local R2="${R2_OF[$SAMPLE]}"
    local CLEAN_R1="${OUTPUT_DIR}/${SAMPLE}_clean_R1.fastq.gz"
    local CLEAN_R2="${OUTPUT_DIR}/${SAMPLE}_clean_R2.fastq.gz"

    log_step "Processing sample: ${SAMPLE}"
    if [[ ! -f "${R1}" || ! -f "${R2}" ]]; then
        log "ERROR: Raw reads not found for sample '${SAMPLE}': ${R1} / ${R2}"
        return 1
    fi

    local BEFORE_R1 BEFORE_R2 AFTER_R1 AFTER_R2
    BEFORE_R1=$(count_fastq_reads "${R1}")
    BEFORE_R2=$(count_fastq_reads "${R2}")
    log "  [${SAMPLE}] R1/R2 raw reads: ${BEFORE_R1} / ${BEFORE_R2}"

    log "  [${SAMPLE}] Running fastp..."
    fastp \
        -i "${R1}" -I "${R2}" \
        -o "${CLEAN_R1}" -O "${CLEAN_R2}" \
        -q "${QUALITY_THRESHOLD}" \
        -l "${MIN_LENGTH}" \
        --thread "${THREADS_PER_JOB}" \
        --json "${OUTPUT_DIR}/${SAMPLE}_fastp.json" \
        --html "${OUTPUT_DIR}/${SAMPLE}_fastp.html"

    if [[ "${REMOVE_HOST}" == "yes" ]]; then
        log "  [${SAMPLE}] Removing host reads..."
        bowtie2 -x "${HOST_INDEX}" \
            -1 "${CLEAN_R1}" -2 "${CLEAN_R2}" \
            --threads "${THREADS_PER_JOB}" \
            --un-conc-gz "${OUTPUT_DIR}/${SAMPLE}_nohost_%.fastq.gz" \
            -S /dev/null 2>"${OUTPUT_DIR}/${SAMPLE}_host_removal.log"
        mv "${OUTPUT_DIR}/${SAMPLE}_nohost_1.fastq.gz" "${CLEAN_R1}"
        mv "${OUTPUT_DIR}/${SAMPLE}_nohost_2.fastq.gz" "${CLEAN_R2}"
    fi

    if [[ "${REMOVE_PHIX}" == "yes" ]]; then
        log "  [${SAMPLE}] Removing PhiX reads..."
        bowtie2 -x "${PHIX_REF_INDEX}" \
            -1 "${CLEAN_R1}" -2 "${CLEAN_R2}" \
            --threads "${THREADS_PER_JOB}" \
            --un-conc-gz "${OUTPUT_DIR}/${SAMPLE}_nophix_%.fastq.gz" \
            -S /dev/null 2>"${OUTPUT_DIR}/${SAMPLE}_phix_removal.log"
        mv "${OUTPUT_DIR}/${SAMPLE}_nophix_1.fastq.gz" "${CLEAN_R1}"
        mv "${OUTPUT_DIR}/${SAMPLE}_nophix_2.fastq.gz" "${CLEAN_R2}"
    fi

    AFTER_R1=$(count_fastq_reads "${CLEAN_R1}")
    AFTER_R2=$(count_fastq_reads "${CLEAN_R2}")
    log "  [${SAMPLE}] clean reads R1/R2: ${AFTER_R1} / ${AFTER_R2}"
    printf '%d\t%d\n' "$((BEFORE_R1 + BEFORE_R2))" "$((AFTER_R1 + AFTER_R2))" \
        > "${OUTPUT_DIR}/${SAMPLE}.qcstats"
    log "  [${SAMPLE}] QC completed."
}

# Restrict to this task's sample under a scheduler array job.
mapfile -t RUN_SAMPLES < <(resolve_task_samples "${SAMPLES[@]}")
log "Processing ${#RUN_SAMPLES[@]} sample(s) with up to ${PARALLEL_JOBS} concurrent job(s)."
run_parallel "${PARALLEL_JOBS}" process_qc_sample "${RUN_SAMPLES[@]}"

# Aggregate per-sample stats produced by this invocation.
for SAMPLE in "${RUN_SAMPLES[@]}"; do
    STATS_FILE="${OUTPUT_DIR}/${SAMPLE}.qcstats"
    if [[ -f "${STATS_FILE}" ]]; then
        IFS=$'\t' read -r S_BEFORE S_AFTER < "${STATS_FILE}"
        TOTAL_BEFORE=$((TOTAL_BEFORE + S_BEFORE))
        TOTAL_AFTER=$((TOTAL_AFTER + S_AFTER))
    fi
done

# ===== QC summary =====
log_step "QC Summary"
log "Total raw reads   : ${TOTAL_BEFORE}"
log "Total clean reads : ${TOTAL_AFTER}"
RETENTION="N/A"
if [[ "${TOTAL_BEFORE}" -gt 0 ]]; then
    RETENTION=$(awk "BEGIN {printf \"%.2f\", 100 * ${TOTAL_AFTER} / ${TOTAL_BEFORE}}")
    log "Retention rate    : ${RETENTION}%"
fi
log "Output directory  : ${OUTPUT_DIR}/"

# ===== Update status and run log =====
update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

# Update run_log.md
if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"
    cat >> "${RUN_LOG}" << EOFRUNLOGQC

### 01 Quality control (Quality Control)
- **Input**: ${#SAMPLES[@]} samples (×2 R1+R2)
- **Parameters**: Q >= ${QUALITY_THRESHOLD}, min_len = ${MIN_LENGTH} bp
- **Total raw reads**: ${TOTAL_BEFORE}
- **Total clean reads**: ${TOTAL_AFTER}
- **Retention**: ${RETENTION}%
- **Detailed log**: logs/01_qc.log

EOFRUNLOGQC
fi

log_step "Quality control completed successfully"
echo ""
echo "Next step: bash 02_assembly.sh"
