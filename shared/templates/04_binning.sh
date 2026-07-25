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
SAMPLES=({{SAMPLE_LIST}})

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
ASSEMBLY_DIR="${RESULTS_DIR}/02_assembly"
MAPPING_DIR="${RESULTS_DIR}/03_mapping"
OUTPUT_DIR="${RESULTS_DIR}/04_binning"

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

# ===== Resolve contig and depth files =====
if [[ "${ASSEMBLY_STRATEGY}" == "co-assembly" ]]; then
    COASSEMBLY_DIR="${ASSEMBLY_DIR}/coassembly"
    CONTIGS_FILE="${COASSEMBLY_DIR}/final.contigs_filtered.fa"
    [[ -f "${CONTIGS_FILE}" ]] || CONTIGS_FILE="${COASSEMBLY_DIR}/final.contigs.fa"
    [[ -f "${CONTIGS_FILE}" ]] || CONTIGS_FILE="${COASSEMBLY_DIR}/contigs.fasta"
    log "Co-assembly mode — contigs: ${CONTIGS_FILE}"
    SINGLE_CONTIG=true
else
    SINGLE_CONTIG=false
fi

# ===== Execution =====
log_step "Starting binning"
log "Min contig length: ${MIN_CONTIG} bp"
log "Tools: metabat2=${USE_METABAT2}, maxbin2=${USE_MAXBIN2}, concoct=${USE_CONCOCT}"
log "DAS Tool: ${USE_DAS_TOOL}"
log "Threads: ${THREADS}"
mkdir -p "${OUTPUT_DIR}"

START_TIME=$(date '+%H:%M')

TOTAL_BINS_BEFORE=0
TOTAL_BINS_AFTER=0

# Bin each sample or the co-assembly
if [[ "${SINGLE_CONTIG}" == true ]]; then
    SAMPLE_LIST_BIN=("coassembly")
else
    SAMPLE_LIST_BIN=("${SAMPLES[@]}")
fi

for SAMPLE in "${SAMPLE_LIST_BIN[@]}"; do
    log_step "Binning: ${SAMPLE}"

    # Resolve the contig file
    if [[ "${SINGLE_CONTIG}" == true ]]; then
        CUR_CONTIGS="${CONTIGS_FILE}"
    else
        CUR_CONTIGS="${ASSEMBLY_DIR}/${SAMPLE}/final.contigs_filtered.fa"
        [[ -f "${CUR_CONTIGS}" ]] || CUR_CONTIGS="${ASSEMBLY_DIR}/${SAMPLE}/final.contigs.fa"
        [[ -f "${CUR_CONTIGS}" ]] || CUR_CONTIGS="${ASSEMBLY_DIR}/${SAMPLE}/contigs.fasta"
    fi

    # Resolve the depth file.
    if [[ "${SINGLE_CONTIG}" == true ]]; then
        DEPTH_FILE="${MAPPING_DIR}/coassembly_depth.txt"
    else
        DEPTH_FILE="${MAPPING_DIR}/${SAMPLE}/${SAMPLE}_depth.txt"
    fi

    if [[ ! -f "${CUR_CONTIGS}" ]]; then
        log "ERROR: Contigs file not found: ${CUR_CONTIGS}"
        exit 1
    fi
    log "  Contigs: ${CUR_CONTIGS}"

    SAMPLE_OUT="${OUTPUT_DIR}/${SAMPLE}"
    mkdir -p "${SAMPLE_OUT}"

    # === MetaBAT2 ===
    if [[ "${USE_METABAT2}" == "yes" ]]; then
        log_step "Running MetaBAT2 for ${SAMPLE}"
        mkdir -p "${SAMPLE_OUT}/metabat2"

        if [[ -f "${DEPTH_FILE}" ]]; then
            metabat2 \
                -i "${CUR_CONTIGS}" \
                -o "${SAMPLE_OUT}/metabat2/bin" \
                -a "${DEPTH_FILE}" \
                -m "${MIN_CONTIG}" \
                -t "${THREADS}"
        else
            log "  WARNING: Depth file not found (${DEPTH_FILE}), running MetaBAT2 without abundance info..."
            metabat2 \
                -i "${CUR_CONTIGS}" \
                -o "${SAMPLE_OUT}/metabat2/bin" \
                -m "${MIN_CONTIG}" \
                -t "${THREADS}"
        fi

        MB2_COUNT=$(find "${SAMPLE_OUT}/metabat2" -maxdepth 1 -type f -name 'bin.*.fa' | wc -l)
        log "  MetaBAT2 bins: ${MB2_COUNT}"
        TOTAL_BINS_BEFORE=$((TOTAL_BINS_BEFORE + MB2_COUNT))
    fi

    # === MaxBin2 ===
    if [[ "${USE_MAXBIN2}" == "yes" ]]; then
        log_step "Running MaxBin2 for ${SAMPLE}"
        mkdir -p "${SAMPLE_OUT}/maxbin2"

        if [[ -f "${DEPTH_FILE}" ]]; then
            MAXBIN_ABUND="${SAMPLE_OUT}/maxbin2/abundance.tsv"
            awk -F'\t' 'NR > 1 {print $1 "\t" $3}' "${DEPTH_FILE}" > "${MAXBIN_ABUND}"
            run_MaxBin.pl \
                -contig "${CUR_CONTIGS}" \
                -abund "${MAXBIN_ABUND}" \
                -out "${SAMPLE_OUT}/maxbin2/bin" \
                -thread "${THREADS}" \
                -min_contig_length "${MIN_CONTIG}"
        else
            log "  WARNING: No depth file, MaxBin2 may not perform optimally"
            run_MaxBin.pl \
                -contig "${CUR_CONTIGS}" \
                -out "${SAMPLE_OUT}/maxbin2/bin" \
                -thread "${THREADS}" \
                -min_contig_length "${MIN_CONTIG}"
        fi

        # Normalize MaxBin2 .fasta output to .fa
        for f in "${SAMPLE_OUT}/maxbin2/"*.fasta; do
            [[ -e "${f}" ]] || continue
            mv "${f}" "${f%.fasta}.fa"
        done

        MX2_COUNT=$(find "${SAMPLE_OUT}/maxbin2" -maxdepth 1 -type f -name 'bin.*.fa' | wc -l)
        log "  MaxBin2 bins: ${MX2_COUNT}"
        TOTAL_BINS_BEFORE=$((TOTAL_BINS_BEFORE + MX2_COUNT))
    fi

    # === CONCOCT ===
    if [[ "${USE_CONCOCT}" == "yes" ]]; then
        log_step "Running CONCOCT for ${SAMPLE}"
        mkdir -p "${SAMPLE_OUT}/concoct"

        # Step 1: Split contigs
        log "  Cutting contigs..."
        cut_up_fasta.py "${CUR_CONTIGS}" -c 10000 -o 0 --merge_last \
            > "${SAMPLE_OUT}/concoct/contigs_10K.fa"

        # Step 2: Build the BAM list
        log "  Generating BAM list..."
        if [[ "${SINGLE_CONTIG}" == true ]]; then
            # Co-assembly: collect BAM files from all samples
            > "${SAMPLE_OUT}/concoct/bam_list.txt"
            for s in "${SAMPLES[@]}"; do
                BAM_FILE="${MAPPING_DIR}/${s}/${s}.sorted.bam"
                if [[ -f "${BAM_FILE}" ]]; then
                    echo "${BAM_FILE}" >> "${SAMPLE_OUT}/concoct/bam_list.txt"
                fi
            done
        else
            BAM_FILE="${MAPPING_DIR}/${SAMPLE}/${SAMPLE}.sorted.bam"
            if [[ -f "${BAM_FILE}" ]]; then
                echo "${BAM_FILE}" > "${SAMPLE_OUT}/concoct/bam_list.txt"
            else
                : > "${SAMPLE_OUT}/concoct/bam_list.txt"
            fi
        fi

        if [[ ! -s "${SAMPLE_OUT}/concoct/bam_list.txt" ]]; then
            log "ERROR: CONCOCT requires at least one readable BAM file."
            exit 1
        fi

        # Step 3: Build the coverage table
        log "  Generating coverage table..."
        concoct_coverage_table.py "${SAMPLE_OUT}/concoct/bam_list.txt" \
            > "${SAMPLE_OUT}/concoct/coverage_table.tsv"

        # Step 4: Cluster contigs
        log "  Running CONCOCT clustering..."
        concoct \
            --composition_file "${SAMPLE_OUT}/concoct/contigs_10K.fa" \
            --coverage_file "${SAMPLE_OUT}/concoct/coverage_table.tsv" \
            -b "${SAMPLE_OUT}/concoct/" \
            --threads "${THREADS}"

        # Step 5: Merge subcontig assignments
        log "  Merging subcontigs..."
        merge_cutup_clustering.py "${SAMPLE_OUT}/concoct/clustering_gt1000.csv" \
            > "${SAMPLE_OUT}/concoct/clustering_merged.csv"

        # Step 6: Extract bins
        log "  Extracting bins..."
        extract_fasta_bins.py "${CUR_CONTIGS}" \
            "${SAMPLE_OUT}/concoct/clustering_merged.csv" \
            --output_path "${SAMPLE_OUT}/concoct/bins"

        CC_COUNT=$(find "${SAMPLE_OUT}/concoct/bins" -maxdepth 1 -type f -name '*.fa' | wc -l)
        log "  CONCOCT bins: ${CC_COUNT}"
        TOTAL_BINS_BEFORE=$((TOTAL_BINS_BEFORE + CC_COUNT))
    fi
done

# === DAS Tool refinement ===
if [[ "${USE_DAS_TOOL}" == "yes" ]]; then
    log_step "Running DAS Tool"
    if command -v Fasta_to_Contigs2Bin.sh &>/dev/null; then
        FASTA_TO_CONTIG2BIN="Fasta_to_Contigs2Bin.sh"
    elif command -v Fasta_to_Contig2Bin.sh &>/dev/null; then
        FASTA_TO_CONTIG2BIN="Fasta_to_Contig2Bin.sh"
    else
        log "ERROR: DAS Tool FASTA-to-contig2bin helper was not found on PATH."
        exit 1
    fi

    for SAMPLE in "${SAMPLE_LIST_BIN[@]}"; do
        SAMPLE_OUT="${OUTPUT_DIR}/${SAMPLE}"
        DAS_OUT="${SAMPLE_OUT}/das_tool"
        mkdir -p "${DAS_OUT}"

        BIN_TABLES=()
        BIN_LABELS=()

        if [[ "${USE_METABAT2}" == "yes" ]]; then
            TABLE="${DAS_OUT}/metabat2_contigs2bin.tsv"
            "${FASTA_TO_CONTIG2BIN}" -i "${SAMPLE_OUT}/metabat2" -e fa > "${TABLE}"
            BIN_TABLES+=("${TABLE}")
            BIN_LABELS+=("metabat2")
        fi
        if [[ "${USE_MAXBIN2}" == "yes" ]]; then
            TABLE="${DAS_OUT}/maxbin2_contigs2bin.tsv"
            "${FASTA_TO_CONTIG2BIN}" -i "${SAMPLE_OUT}/maxbin2" -e fa > "${TABLE}"
            BIN_TABLES+=("${TABLE}")
            BIN_LABELS+=("maxbin2")
        fi
        if [[ "${USE_CONCOCT}" == "yes" ]]; then
            TABLE="${DAS_OUT}/concoct_contigs2bin.tsv"
            "${FASTA_TO_CONTIG2BIN}" -i "${SAMPLE_OUT}/concoct/bins" -e fa > "${TABLE}"
            BIN_TABLES+=("${TABLE}")
            BIN_LABELS+=("concoct")
        fi

        BIN_ARGS=$(IFS=,; echo "${BIN_TABLES[*]}")
        LABEL_ARGS=$(IFS=,; echo "${BIN_LABELS[*]}")

        if [[ -z "${BIN_ARGS}" ]]; then
            log "  No bin sets to integrate — skipping DAS Tool"
        else
            if [[ "${SINGLE_CONTIG}" == true ]]; then
                CUR_CONTIGS="${CONTIGS_FILE}"
            else
                CUR_CONTIGS="${ASSEMBLY_DIR}/${SAMPLE}/final.contigs_filtered.fa"
                [[ -f "${CUR_CONTIGS}" ]] || CUR_CONTIGS="${ASSEMBLY_DIR}/${SAMPLE}/final.contigs.fa"
                [[ -f "${CUR_CONTIGS}" ]] || CUR_CONTIGS="${ASSEMBLY_DIR}/${SAMPLE}/contigs.fasta"
            fi

            DAS_Tool \
                -i "${BIN_ARGS}" \
                -l "${LABEL_ARGS}" \
                -c "${CUR_CONTIGS}" \
                -o "${DAS_OUT}/DASTool" \
                -t "${THREADS}" \
                --score_threshold 0.5 \
                --write_bins

            DAS_BIN_DIR="${DAS_OUT}/DASTool_DASTool_bins"
            DAS_COUNT=$(find "${DAS_BIN_DIR}" -maxdepth 1 -type f -name '*.fa' | wc -l)
            log "  DAS Tool ${SAMPLE}: ${DAS_COUNT} refined bins"
            TOTAL_BINS_AFTER=$((TOTAL_BINS_AFTER + DAS_COUNT))
        fi
    done
fi

# ===== Summary =====
log_step "Binning Summary"
log "Total bins before DAS Tool: ${TOTAL_BINS_BEFORE}"
log "Total refined bins: ${TOTAL_BINS_AFTER}"
log "Output directory: ${OUTPUT_DIR}/"

# ===== Update status and run log =====
update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"
    cat >> "${RUN_LOG}" << EOFRUNLOGBIN

### 04 Binning (Binning)
- **Tool**: MetaBAT2=${USE_METABAT2}, MaxBin2=${USE_MAXBIN2}, CONCOCT=${USE_CONCOCT}
- **DAS Tool refinement**: ${USE_DAS_TOOL}
- **Minimum contig length**: ${MIN_CONTIG} bp
- **Total bins before refinement**: ${TOTAL_BINS_BEFORE}
- **Total bins after refinement**: ${TOTAL_BINS_AFTER}
- **Output**: ${OUTPUT_DIR}/
- **Detailed log**: logs/04_binning.log

EOFRUNLOGBIN
fi

log_step "Binning completed"
echo "Next step: bash 05_bin_evaluation.sh"
