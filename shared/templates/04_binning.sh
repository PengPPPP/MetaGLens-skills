#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_binning
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --mem={{MEMORY}}
#SBATCH --output=metaglens_results/reports/logs/04_binning_%j.log

set -euo pipefail

# ===== Load pipeline utilities =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "${SCRIPT_DIR}/pipeline_utils.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/pipeline_utils.sh is required." >&2
    exit 1
fi
source "${SCRIPT_DIR}/pipeline_utils.sh"

# ===== Parameters =====
STEP_NAME="04_binning"
WORK_DIR="{{WORK_DIR}}"
CONDA_ENV="{{CONDA_ENV}}"
THREADS={{THREADS}}
MIN_CONTIG={{MIN_CONTIG}}
USE_METABAT2="{{USE_METABAT2}}"
USE_MAXBIN2="{{USE_MAXBIN2}}"
USE_CONCOCT="{{USE_CONCOCT}}"
USE_DAS_TOOL="{{USE_DAS_TOOL}}"
ASSEMBLY_STRATEGY="{{ASSEMBLY_STRATEGY}}"
# Label used to prefix renamed bins for a co-binning (co-assembly) run.
GROUP_LABEL="{{GROUP_LABEL}}"
SAMPLES=({{SAMPLE_LIST}})

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
ASSEMBLY_DIR="${RESULTS_DIR}/02_assembly"
MAPPING_DIR="${RESULTS_DIR}/03_mapping"
OUTPUT_DIR="${RESULTS_DIR}/04_binning"
# Collected, renamed bins ({label}_bin{N}.fa) from all samples for downstream stages.
ALL_BINS_DIR="${OUTPUT_DIR}/all_bins"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
LOG_FILE="${LOG_DIR}/04_binning.log"

# ===== Activate the Conda environment when available=====
if [[ -n "${CONDA_ENV}" && "${CONDA_ENV}" != "none" ]] && command -v conda &>/dev/null; then
    eval "$(conda shell.bash hook)"
    conda activate "${CONDA_ENV}" || log "WARNING: failed to activate env '${CONDA_ENV}', assuming tools on PATH."
fi

# ===== Resume and status checks =====
log_step "MetaGLens Binning — 04_binning.sh"
init_status_if_missing

if ! check_step_completed "${STEP_NAME}"; then
    log "Skipping binning (already completed)."
    exit 0
fi

check_prerequisite "03_mapping"
update_step_status "${STEP_NAME}" "running"
enable_step_failure_trap

# ===== Parallel plan =====
# Per-sample binning supports scheduler array jobs (one task per sample).
# Co-binning is a single unit that uses all available threads.
load_parallel_plan
log "Parallel plan: exec_env=${EXEC_ENV}, jobs=${PARALLEL_JOBS}, threads/job=${THREADS_PER_JOB}, total=${TOTAL_THREADS}"

# ===== Resolve binning units =====
# Per-sample binning: one unit per sample, labeled by sample id.
# Co-binning (co-assembly): a single unit over the shared contigs, labeled GROUP_LABEL.
if [[ "${ASSEMBLY_STRATEGY}" == "co-assembly" ]]; then
    SINGLE_CONTIG=true
    BIN_UNITS=("coassembly")
    COASSEMBLY_DIR="${ASSEMBLY_DIR}/coassembly"
    COASSEMBLY_CONTIGS="${COASSEMBLY_DIR}/final.contigs_filtered.fa"
    [[ -f "${COASSEMBLY_CONTIGS}" ]] || COASSEMBLY_CONTIGS="${COASSEMBLY_DIR}/final.contigs.fa"
    [[ -f "${COASSEMBLY_CONTIGS}" ]] || COASSEMBLY_CONTIGS="${COASSEMBLY_DIR}/contigs.fasta"
    log "Co-binning mode — shared contigs: ${COASSEMBLY_CONTIGS}"
else
    SINGLE_CONTIG=false
    BIN_UNITS=("${SAMPLES[@]}")
fi

# ===== Execution =====
log_step "Starting binning"
log "Min contig length: ${MIN_CONTIG} bp"
log "Tools: metabat2=${USE_METABAT2}, maxbin2=${USE_MAXBIN2}, concoct=${USE_CONCOCT}, DAS Tool=${USE_DAS_TOOL}"
mkdir -p "${OUTPUT_DIR}" "${ALL_BINS_DIR}"

START_TIME=$(date '+%H:%M')

# Restrict to this task's unit under a scheduler array job.
mapfile -t RUN_UNITS < <(resolve_task_samples "${BIN_UNITS[@]}")
# With a single binning unit, use all threads; otherwise split across parallel jobs.
if [[ ${#RUN_UNITS[@]} -le 1 ]]; then
    BIN_THREADS="${TOTAL_THREADS}"
else
    BIN_THREADS="${THREADS_PER_JOB}"
fi

# Resolve the DAS Tool FASTA-to-contig2bin helper name once.
FASTA_TO_CONTIG2BIN=""
if [[ "${USE_DAS_TOOL}" == "yes" ]]; then
    if command -v Fasta_to_Contigs2Bin.sh &>/dev/null; then
        FASTA_TO_CONTIG2BIN="Fasta_to_Contigs2Bin.sh"
    elif command -v Fasta_to_Contig2Bin.sh &>/dev/null; then
        FASTA_TO_CONTIG2BIN="Fasta_to_Contig2Bin.sh"
    else
        log "ERROR: DAS Tool FASTA-to-contig2bin helper was not found on PATH."
        exit 1
    fi
fi

# Bin a single unit (sample or co-assembly), refine, then rename + collect bins.
bin_unit() {
    local SAMPLE="$1"
    local CUR_CONTIGS DEPTH_FILE LABEL
    local SAMPLE_OUT="${OUTPUT_DIR}/${SAMPLE}"
    mkdir -p "${SAMPLE_OUT}"

    # Naming label: co-binning uses GROUP_LABEL; per-sample uses the sample id.
    if [[ "${SINGLE_CONTIG}" == true ]]; then
        CUR_CONTIGS="${COASSEMBLY_CONTIGS}"
        DEPTH_FILE="${MAPPING_DIR}/coassembly_depth.txt"
        LABEL="${GROUP_LABEL}"
    else
        CUR_CONTIGS="${ASSEMBLY_DIR}/${SAMPLE}/final.contigs_filtered.fa"
        [[ -f "${CUR_CONTIGS}" ]] || CUR_CONTIGS="${ASSEMBLY_DIR}/${SAMPLE}/final.contigs.fa"
        [[ -f "${CUR_CONTIGS}" ]] || CUR_CONTIGS="${ASSEMBLY_DIR}/${SAMPLE}/contigs.fasta"
        DEPTH_FILE="${MAPPING_DIR}/${SAMPLE}/${SAMPLE}_depth.txt"
        LABEL="${SAMPLE}"
    fi

    if [[ ! -f "${CUR_CONTIGS}" ]]; then
        log "ERROR: Contigs file not found: ${CUR_CONTIGS}"
        return 1
    fi
    log_step "Binning: ${SAMPLE} (label: ${LABEL})"
    log "  [${SAMPLE}] Contigs: ${CUR_CONTIGS}"

    # === MetaBAT2 ===
    if [[ "${USE_METABAT2}" == "yes" ]]; then
        mkdir -p "${SAMPLE_OUT}/metabat2"
        if [[ -f "${DEPTH_FILE}" ]]; then
            metabat2 -i "${CUR_CONTIGS}" -o "${SAMPLE_OUT}/metabat2/bin" \
                -a "${DEPTH_FILE}" -m "${MIN_CONTIG}" -t "${BIN_THREADS}"
        else
            log "  [${SAMPLE}] WARNING: depth file missing (${DEPTH_FILE}); running MetaBAT2 without abundance."
            metabat2 -i "${CUR_CONTIGS}" -o "${SAMPLE_OUT}/metabat2/bin" \
                -m "${MIN_CONTIG}" -t "${BIN_THREADS}"
        fi
    fi

    # === MaxBin2 ===
    if [[ "${USE_MAXBIN2}" == "yes" ]]; then
        mkdir -p "${SAMPLE_OUT}/maxbin2"
        if [[ -f "${DEPTH_FILE}" ]]; then
            awk -F'\t' 'NR > 1 {print $1 "\t" $3}' "${DEPTH_FILE}" > "${SAMPLE_OUT}/maxbin2/abundance.tsv"
            run_MaxBin.pl -contig "${CUR_CONTIGS}" -abund "${SAMPLE_OUT}/maxbin2/abundance.tsv" \
                -out "${SAMPLE_OUT}/maxbin2/bin" -thread "${BIN_THREADS}" -min_contig_length "${MIN_CONTIG}"
        else
            log "  [${SAMPLE}] WARNING: no depth file; MaxBin2 may not perform optimally."
            run_MaxBin.pl -contig "${CUR_CONTIGS}" -out "${SAMPLE_OUT}/maxbin2/bin" \
                -thread "${BIN_THREADS}" -min_contig_length "${MIN_CONTIG}"
        fi
        # Normalize MaxBin2 .fasta output to .fa
        for f in "${SAMPLE_OUT}/maxbin2/"*.fasta; do
            [[ -e "${f}" ]] || continue
            mv "${f}" "${f%.fasta}.fa"
        done
    fi

    # === CONCOCT ===
    if [[ "${USE_CONCOCT}" == "yes" ]]; then
        mkdir -p "${SAMPLE_OUT}/concoct"
        cut_up_fasta.py "${CUR_CONTIGS}" -c 10000 -o 0 --merge_last \
            > "${SAMPLE_OUT}/concoct/contigs_10K.fa"
        : > "${SAMPLE_OUT}/concoct/bam_list.txt"
        if [[ "${SINGLE_CONTIG}" == true ]]; then
            # Co-binning: collect BAM files from all samples.
            local s
            for s in "${SAMPLES[@]}"; do
                local co_bam="${MAPPING_DIR}/${s}/${s}.sorted.bam"
                [[ -f "${co_bam}" ]] && echo "${co_bam}" >> "${SAMPLE_OUT}/concoct/bam_list.txt"
            done
        else
            local ps_bam="${MAPPING_DIR}/${SAMPLE}/${SAMPLE}.sorted.bam"
            [[ -f "${ps_bam}" ]] && echo "${ps_bam}" >> "${SAMPLE_OUT}/concoct/bam_list.txt"
        fi
        if [[ ! -s "${SAMPLE_OUT}/concoct/bam_list.txt" ]]; then
            log "ERROR: CONCOCT requires at least one readable BAM file."
            return 1
        fi
        concoct_coverage_table.py "${SAMPLE_OUT}/concoct/bam_list.txt" \
            > "${SAMPLE_OUT}/concoct/coverage_table.tsv"
        concoct --composition_file "${SAMPLE_OUT}/concoct/contigs_10K.fa" \
            --coverage_file "${SAMPLE_OUT}/concoct/coverage_table.tsv" \
            -b "${SAMPLE_OUT}/concoct/" --threads "${BIN_THREADS}"
        merge_cutup_clustering.py "${SAMPLE_OUT}/concoct/clustering_gt1000.csv" \
            > "${SAMPLE_OUT}/concoct/clustering_merged.csv"
        extract_fasta_bins.py "${CUR_CONTIGS}" \
            "${SAMPLE_OUT}/concoct/clustering_merged.csv" \
            --output_path "${SAMPLE_OUT}/concoct/bins"
    fi

    # === Choose the final bin set for this unit ===
    # With DAS Tool: integrate binners into a refined consensus set.
    # Without DAS Tool: use the first enabled binner's output as the final set.
    local FINAL_BIN_DIR=""
    if [[ "${USE_DAS_TOOL}" == "yes" ]]; then
        local DAS_OUT="${SAMPLE_OUT}/das_tool"
        mkdir -p "${DAS_OUT}"
        local BIN_TABLES=() BIN_LABELS=()
        if [[ "${USE_METABAT2}" == "yes" ]]; then
            "${FASTA_TO_CONTIG2BIN}" -i "${SAMPLE_OUT}/metabat2" -e fa > "${DAS_OUT}/metabat2_contigs2bin.tsv"
            BIN_TABLES+=("${DAS_OUT}/metabat2_contigs2bin.tsv"); BIN_LABELS+=("metabat2")
        fi
        if [[ "${USE_MAXBIN2}" == "yes" ]]; then
            "${FASTA_TO_CONTIG2BIN}" -i "${SAMPLE_OUT}/maxbin2" -e fa > "${DAS_OUT}/maxbin2_contigs2bin.tsv"
            BIN_TABLES+=("${DAS_OUT}/maxbin2_contigs2bin.tsv"); BIN_LABELS+=("maxbin2")
        fi
        if [[ "${USE_CONCOCT}" == "yes" ]]; then
            "${FASTA_TO_CONTIG2BIN}" -i "${SAMPLE_OUT}/concoct/bins" -e fa > "${DAS_OUT}/concoct_contigs2bin.tsv"
            BIN_TABLES+=("${DAS_OUT}/concoct_contigs2bin.tsv"); BIN_LABELS+=("concoct")
        fi
        local BIN_ARGS LABEL_ARGS
        BIN_ARGS=$(IFS=,; echo "${BIN_TABLES[*]}")
        LABEL_ARGS=$(IFS=,; echo "${BIN_LABELS[*]}")
        if [[ -z "${BIN_ARGS}" ]]; then
            log "  [${SAMPLE}] No bin sets to integrate — skipping DAS Tool."
        else
            DAS_Tool -i "${BIN_ARGS}" -l "${LABEL_ARGS}" -c "${CUR_CONTIGS}" \
                -o "${DAS_OUT}/DASTool" -t "${BIN_THREADS}" \
                --score_threshold 0.5 --write_bins
            FINAL_BIN_DIR="${DAS_OUT}/DASTool_DASTool_bins"
        fi
    fi
    if [[ -z "${FINAL_BIN_DIR}" ]]; then
        # No DAS Tool (or nothing to integrate): pick the first enabled binner.
        if [[ "${USE_METABAT2}" == "yes" ]]; then FINAL_BIN_DIR="${SAMPLE_OUT}/metabat2"
        elif [[ "${USE_MAXBIN2}" == "yes" ]]; then FINAL_BIN_DIR="${SAMPLE_OUT}/maxbin2"
        elif [[ "${USE_CONCOCT}" == "yes" ]]; then FINAL_BIN_DIR="${SAMPLE_OUT}/concoct/bins"
        fi
    fi

    # === Rename final bins to {label}_bin{N}.fa and collect into all_bins/ ===
    local before_count=0 after_count=0
    shopt -s nullglob
    local final_bins=("${FINAL_BIN_DIR}"/*.fa "${FINAL_BIN_DIR}"/*.fna "${FINAL_BIN_DIR}"/*.fasta)
    shopt -u nullglob
    before_count=${#final_bins[@]}
    local n=0 bin
    for bin in "${final_bins[@]}"; do
        n=$((n + 1))
        cp "${bin}" "${ALL_BINS_DIR}/${LABEL}_bin${n}.fa"
        after_count=$((after_count + 1))
    done
    log "  [${SAMPLE}] Final bins: ${before_count}; collected as ${LABEL}_bin*.fa"
    printf '%d\t%d\n' "${before_count}" "${after_count}" > "${SAMPLE_OUT}/.bincount"
}

log "Binning ${#RUN_UNITS[@]} unit(s) with up to ${PARALLEL_JOBS} concurrent job(s); ${BIN_THREADS} threads/unit."
run_parallel "${PARALLEL_JOBS}" bin_unit "${RUN_UNITS[@]}"

# ===== Aggregate counts =====
TOTAL_BINS=0
for UNIT in "${RUN_UNITS[@]}"; do
    CFILE="${OUTPUT_DIR}/${UNIT}/.bincount"
    if [[ -f "${CFILE}" ]]; then
        IFS=$'\t' read -r B _A < "${CFILE}"
        TOTAL_BINS=$((TOTAL_BINS + B))
    fi
done
COLLECTED_TOTAL=$(find "${ALL_BINS_DIR}" -maxdepth 1 -type f -name '*.fa' | wc -l)

# ===== Summary =====
log_step "Binning Summary"
log "Total final bins produced: ${TOTAL_BINS}"
log "Collected renamed bins in ${ALL_BINS_DIR}/: ${COLLECTED_TOTAL}"
log "Output directory: ${OUTPUT_DIR}/"

# ===== Update status and run log =====
update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"
    cat >> "${RUN_LOG}" << EOFRUNLOGBIN

### 04 Binning (Binning)
- **Tools**: MetaBAT2=${USE_METABAT2}, MaxBin2=${USE_MAXBIN2}, CONCOCT=${USE_CONCOCT}
- **DAS Tool refinement**: ${USE_DAS_TOOL}
- **Binning strategy**: ${ASSEMBLY_STRATEGY}
- **Minimum contig length**: ${MIN_CONTIG} bp
- **Total final bins**: ${TOTAL_BINS}
- **Collected (renamed {label}_bin{N}.fa)**: ${COLLECTED_TOTAL} in all_bins/
- **Output**: ${OUTPUT_DIR}/
- **Detailed log**: logs/04_binning.log

EOFRUNLOGBIN
fi

log_step "Binning completed"
echo "Next step: bash 05_bin_evaluation.sh (use BINS_DIR=${ALL_BINS_DIR})"
