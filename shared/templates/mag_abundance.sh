#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_mag_abund
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --mem={{MEMORY}}
#SBATCH --output=metaglens_results/reports/logs/mag_abundance_%j.log

set -euo pipefail

# ===== Load pipeline utilities =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "${SCRIPT_DIR}/pipeline_utils.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/pipeline_utils.sh is required." >&2
    exit 1
fi
source "${SCRIPT_DIR}/pipeline_utils.sh"

# ===== Parameters =====
# Estimate per-MAG, per-sample abundance by mapping quality-controlled reads to
# the dereplicated MAG set and aggregating contig coverage to the genome level.
# Produces a MAG x sample mean-depth matrix and a column-normalized relative
# abundance matrix, which stage 10 combines with GTDB-Tk taxonomy for a true
# MAG-route community table.
STEP_NAME="mag_abundance"
WORK_DIR="{{WORK_DIR}}"
CONDA_ENV="{{CONDA_ENV}}"
THREADS={{THREADS}}
ALIGN_TOOL="{{ALIGN_TOOL}}"     # bowtie2 | bwa-mem2
SAMPLES=({{SAMPLE_LIST}})

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
QC_DIR="${RESULTS_DIR}/01_qc"
DEREP_DIR="${RESULTS_DIR}/06_derep/dereplicated_genomes"
OUTPUT_DIR="${RESULTS_DIR}/mag_abundance"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
LOG_FILE="${LOG_DIR}/mag_abundance.log"

# ===== Activate the Conda environment when available =====
if [[ -n "${CONDA_ENV}" && "${CONDA_ENV}" != "none" ]] && command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)"
    conda activate "${CONDA_ENV}" || log "WARNING: failed to activate env '${CONDA_ENV}', assuming tools on PATH."
fi

# ===== Resume and status checks =====
log_step "MetaGLens MAG Abundance — mag_abundance.sh"
init_status_if_missing

if ! check_step_completed "${STEP_NAME}"; then
    log "Skipping MAG abundance (already completed)."
    exit 0
fi

check_prerequisite "06_derep"
update_step_status "${STEP_NAME}" "running"
enable_step_failure_trap

# ===== Parallel plan =====
load_parallel_plan
log "Parallel plan: exec_env=${EXEC_ENV}, jobs=${PARALLEL_JOBS}, threads/job=${THREADS_PER_JOB}, total=${TOTAL_THREADS}"

mkdir -p "${OUTPUT_DIR}"/{bam,coverage}
START_TIME=$(date '+%H:%M')

# ===== Step 1: Build a combined MAG reference =====
# Rewrite every contig header to "{MAG}|{original}" so contigs map back to their
# genome even if contig names collide across MAGs.
COMBINED_REF="${OUTPUT_DIR}/mag_reference.fa"
CONTIG2MAG="${OUTPUT_DIR}/contig2mag.tsv"
: > "${COMBINED_REF}"
printf 'contig\tmag\n' > "${CONTIG2MAG}"

shopt -s nullglob
MAGS=("${DEREP_DIR}"/*.fa "${DEREP_DIR}"/*.fna "${DEREP_DIR}"/*.fasta)
shopt -u nullglob
if [[ ${#MAGS[@]} -eq 0 ]]; then
    log "ERROR: No dereplicated MAGs found in ${DEREP_DIR}."
    exit 1
fi
log "Combining ${#MAGS[@]} dereplicated MAGs into a single reference."
for mag in "${MAGS[@]}"; do
    label=$(basename "${mag}" | sed 's/\.[^.]*$//')
    awk -v L="${label}" -v C2M="${CONTIG2MAG}" '
        /^>/ { id=substr($1,2); print L"|"id"\t"L >> C2M; print ">"L"|"substr($0,2); next }
        { print }
    ' "${mag}" >> "${COMBINED_REF}"
done

# ===== Step 2: Build the alignment index once (all threads) =====
if [[ "${ALIGN_TOOL}" == "bowtie2" ]]; then
    INDEX_PREFIX="${OUTPUT_DIR}/mag_reference_idx"
    log "Building Bowtie2 index (threads=${TOTAL_THREADS})..."
    bowtie2-build --threads "${TOTAL_THREADS}" "${COMBINED_REF}" "${INDEX_PREFIX}"
else
    log "Building bwa-mem2 index..."
    bwa-mem2 index "${COMBINED_REF}"
    INDEX_PREFIX="${COMBINED_REF}"
fi

# ===== Step 3: Map each sample and record per-contig coverage (parallel) =====
compute_sample_coverage() {
    local SAMPLE="$1"
    local R1="${QC_DIR}/${SAMPLE}_clean_R1.fastq.gz"
    local R2="${QC_DIR}/${SAMPLE}_clean_R2.fastq.gz"
    local BAM="${OUTPUT_DIR}/bam/${SAMPLE}.sorted.bam"
    log_step "MAG coverage: ${SAMPLE}"
    if [[ ! -f "${R1}" || ! -f "${R2}" ]]; then
        log "ERROR: QC reads not found for '${SAMPLE}': ${R1} / ${R2}"
        return 1
    fi
    if [[ "${ALIGN_TOOL}" == "bowtie2" ]]; then
        bowtie2 --sensitive -x "${INDEX_PREFIX}" -1 "${R1}" -2 "${R2}" \
            --threads "${THREADS_PER_JOB}" 2>"${OUTPUT_DIR}/bam/${SAMPLE}_bowtie2.log" | \
            samtools sort -@ "${THREADS_PER_JOB}" -o "${BAM}"
    else
        bwa-mem2 mem -t "${THREADS_PER_JOB}" "${INDEX_PREFIX}" "${R1}" "${R2}" | \
            samtools sort -@ "${THREADS_PER_JOB}" -o "${BAM}"
    fi
    samtools index -@ "${THREADS_PER_JOB}" "${BAM}"
    # Per-contig mean depth: columns rname,startpos,endpos,numreads,covbases,coverage,meandepth,...
    samtools coverage "${BAM}" > "${OUTPUT_DIR}/coverage/${SAMPLE}.coverage.tsv"
    log "  [${SAMPLE}] coverage table written."
}

mapfile -t RUN_SAMPLES < <(resolve_task_samples "${SAMPLES[@]}")
log "Estimating abundance for ${#RUN_SAMPLES[@]} sample(s) with up to ${PARALLEL_JOBS} concurrent job(s)."
run_parallel "${PARALLEL_JOBS}" compute_sample_coverage "${RUN_SAMPLES[@]}"

# ===== Step 4: Aggregate contig coverage to per-MAG abundance matrices =====
log_step "Aggregating per-MAG abundance"
MEANDEPTH_OUT="${OUTPUT_DIR}/mag_abundance_mean_depth.tsv"
RELABUND_OUT="${OUTPUT_DIR}/mag_relative_abundance.tsv"

METAGLENS_COVERAGE_DIR="${OUTPUT_DIR}/coverage" \
METAGLENS_SAMPLES="${SAMPLES[*]}" \
METAGLENS_MEANDEPTH_OUT="${MEANDEPTH_OUT}" \
METAGLENS_RELABUND_OUT="${RELABUND_OUT}" \
python3 - <<'PY'
import os

cov_dir = os.environ["METAGLENS_COVERAGE_DIR"]
samples = os.environ["METAGLENS_SAMPLES"].split()
meandepth_out = os.environ["METAGLENS_MEANDEPTH_OUT"]
relabund_out = os.environ["METAGLENS_RELABUND_OUT"]

# mag_depth[mag][sample] = length-weighted mean depth
mag_depth = {}
mags = set()
for sample in samples:
    path = os.path.join(cov_dir, "%s.coverage.tsv" % sample)
    if not os.path.isfile(path):
        continue
    length_sum = {}
    weighted = {}
    with open(path) as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            p = line.rstrip("\n").split("\t")
            if len(p) < 7:
                continue
            rname = p[0]
            try:
                endpos = float(p[2]); meandepth = float(p[6])
            except ValueError:
                continue
            mag = rname.split("|", 1)[0]
            mags.add(mag)
            length_sum[mag] = length_sum.get(mag, 0.0) + endpos
            weighted[mag] = weighted.get(mag, 0.0) + endpos * meandepth
    for mag in length_sum:
        depth = weighted[mag] / length_sum[mag] if length_sum[mag] > 0 else 0.0
        mag_depth.setdefault(mag, {})[sample] = depth

mags = sorted(mags)

# Mean-depth matrix
with open(meandepth_out, "w") as fh:
    fh.write("MAG\t" + "\t".join(samples) + "\n")
    for mag in mags:
        row = ["%.4f" % mag_depth.get(mag, {}).get(s, 0.0) for s in samples]
        fh.write(mag + "\t" + "\t".join(row) + "\n")

# Column-normalized relative abundance (% per sample)
col_totals = {s: sum(mag_depth.get(m, {}).get(s, 0.0) for m in mags) for s in samples}
with open(relabund_out, "w") as fh:
    fh.write("MAG\t" + "\t".join(samples) + "\n")
    for mag in mags:
        row = []
        for s in samples:
            tot = col_totals[s]
            val = (mag_depth.get(mag, {}).get(s, 0.0) / tot * 100.0) if tot > 0 else 0.0
            row.append("%.4f" % val)
        fh.write(mag + "\t" + "\t".join(row) + "\n")

print("Aggregated abundance for %d MAGs across %d samples." % (len(mags), len(samples)))
PY

NUM_MAGS=$(( $(wc -l < "${MEANDEPTH_OUT}") - 1 ))
log "MAG mean-depth matrix     : ${MEANDEPTH_OUT}"
log "MAG relative-abundance (%): ${RELABUND_OUT}"

# ===== Summary =====
log_step "MAG Abundance Summary"
log "MAGs quantified : ${NUM_MAGS}"
log "Samples         : ${#RUN_SAMPLES[@]}"
log "Output directory: ${OUTPUT_DIR}/"

# ===== Update status and run log =====
update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"
    cat >> "${RUN_LOG}" << EOFRUNLOGABU

### MAG abundance (read mapping to dereplicated MAGs)
- **Aligner**: ${ALIGN_TOOL}
- **MAGs quantified**: ${NUM_MAGS}
- **Samples**: ${#RUN_SAMPLES[@]}
- **Mean-depth matrix**: mag_abundance/mag_abundance_mean_depth.tsv
- **Relative abundance (%)**: mag_abundance/mag_relative_abundance.tsv
- **Detailed log**: logs/mag_abundance.log

EOFRUNLOGABU
fi

log_step "MAG abundance completed"
echo "Next step: bash 10_community_summary.sh"
