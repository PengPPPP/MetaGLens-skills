#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_setup
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --output=metaglens_results/reports/logs/00_setup_%j.log

set -Eeuo pipefail

# ===== Parameters =====
PROJECT_NAME="{{PROJECT_NAME}}"
WORK_DIR="{{WORK_DIR}}"
RAW_DATA_DIR="{{RAW_DATA_DIR}}"
CONDA_MODE="{{CONDA_MODE}}"
CONDA_ENV="{{CONDA_ENV}}"
CONDA_ORIGIN="{{CONDA_ORIGIN}}"
MISSING_TOOLS=({{MISSING_TOOLS}})
UPDATE_TOOLS=({{UPDATE_TOOLS}})
SAMPLE_LIST=({{SAMPLE_LIST}})
SAMPLE_PATTERN="{{SAMPLE_PATTERN}}"
SAMPLE_MANIFEST="{{SAMPLE_MANIFEST}}"
THREADS={{THREADS}}
DB_DIR="{{DB_DIR}}"
DOWNLOAD_DBS="{{DOWNLOAD_DBS}}"

STEP_NAME="00_setup"

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
REPAIR_LOG="${REPORTS_DIR}/repair_log.jsonl"
REPAIRS_DIR="${REPORTS_DIR}/repairs"

# ===== Directory layout (create first because log depends on LOG_DIR)=====
mkdir -p "${RESULTS_DIR}"/{01_qc,02_assembly,03_mapping,04_binning,05_checkm,06_derep,07_taxonomy,08_annotation}
mkdir -p "${LOG_DIR}" "${REPAIRS_DIR}"
touch "${REPAIR_LOG}"

# ===== Logging =====
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_DIR}/setup.log"; }

# Validate and normalize the sample manifest.
if [[ ! -r "${SAMPLE_MANIFEST}" ]]; then
    log "ERROR: Sample manifest is not readable: ${SAMPLE_MANIFEST}"
    exit 1
fi
CANONICAL_MANIFEST="${RESULTS_DIR}/samples.tsv"
if [[ "$(readlink -f "${SAMPLE_MANIFEST}")" != "$(readlink -f "${CANONICAL_MANIFEST}" 2>/dev/null || echo "${CANONICAL_MANIFEST}")" ]]; then
    cp "${SAMPLE_MANIFEST}" "${CANONICAL_MANIFEST}"
fi
SAMPLE_MANIFEST="${CANONICAL_MANIFEST}"
if ! awk -F'\t' '
    NR == 1 {next}
    NF != 3 || $1 !~ /^[A-Za-z0-9._-]+$/ {bad=1; next}
    {count++}
    END {exit (!bad && count > 0) ? 0 : 1}
' "${SAMPLE_MANIFEST}"; then
    log "ERROR: samples.tsv must contain sample_id, r1, and r2 columns with safe sample IDs."
    exit 1
fi
mapfile -t SAMPLE_LIST < <(awk -F'\t' 'NR > 1 {print $1}' "${SAMPLE_MANIFEST}")

# ===== Environment names =====
# Create mode uses three environments because installing gtdbtk/checkm2/concoct/prokka together
# often causes dependency conflicts or solver timeouts.
#   *_qc      — fastp/megahit/spades/bowtie2/samtools/seqkit (stages 01-03)
#   *_binning — metabat2/maxbin2/concoct/das_tool (stage 04)
#   *_mag     — checkm2/drep/gtdbtk/kraken2/bracken/prokka/eggnog-mapper (stages 05-08)
if [[ "${CONDA_MODE}" == "create" ]]; then
    ENV_QC="${CONDA_ENV}_qc"
    ENV_BINNING="${CONDA_ENV}_binning"
    ENV_MAG="${CONDA_ENV}_mag"
else
    ENV_QC="${CONDA_ENV}"
    ENV_BINNING="${CONDA_ENV}"
    ENV_MAG="${CONDA_ENV}"
fi

# ===== Status-file functions =====
init_status_file() {
    # Build the samples JSON array in Bash without jq
    local samples_json
    samples_json=$(for s in "${SAMPLE_LIST[@]}"; do printf '"%s",' "$s"; done)
    samples_json="[${samples_json%,}]"

    cat > "${STATUS_FILE}" << EOFSTATUS
{
  "project_name": "${PROJECT_NAME}",
  "work_dir": "${WORK_DIR}",
  "results_dir": "${RESULTS_DIR}",
  "reports_dir": "${REPORTS_DIR}",
  "sample_manifest": "${SAMPLE_MANIFEST}",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "monitoring": {
    "enabled": true,
    "max_auto_repair_attempts": 2
  },
  "steps": {
    "00_setup": {"status": "running", "started": "$(date '+%Y-%m-%d %H:%M:%S')", "attempts": 1},
    "01_qc": {"status": "pending", "attempts": 0},
    "02_assembly": {"status": "pending", "attempts": 0},
    "03_mapping": {"status": "pending", "attempts": 0},
    "04_binning": {"status": "pending", "attempts": 0},
    "05_checkm": {"status": "pending", "attempts": 0},
    "06_derep": {"status": "pending", "attempts": 0},
    "07_taxonomy": {"status": "pending", "attempts": 0},
    "08_annotation": {"status": "pending", "attempts": 0}
  },
  "samples": ${samples_json},
  "sample_pattern": "${SAMPLE_PATTERN}",
  "conda_mode": "${CONDA_MODE}",
  "conda_env": "${CONDA_ENV}",
  "conda_envs": {"qc": "${ENV_QC}", "binning": "${ENV_BINNING}", "mag": "${ENV_MAG}"},
  "conda_origin": "${CONDA_ORIGIN}",
  "collected_methods": []
}
EOFSTATUS
}

update_step_status() {
    local step="$1"
    local status="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    python3 -c "
import json
with open('${STATUS_FILE}', 'r') as f:
    data = json.load(f)
data['steps']['${step}']['status'] = '${status}'
step_data = data['steps']['${step}']
if '${status}' == 'running':
    step_data['started'] = '${timestamp}'
    step_data['attempts'] = int(step_data.get('attempts', 0)) + 1
elif '${status}' == 'completed':
    step_data['finished'] = '${timestamp}'
    step_data['exit_code'] = 0
elif '${status}' == 'failed':
    step_data['failed_at'] = '${timestamp}'
with open('${STATUS_FILE}', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
"
    log "Pipeline status: ${step} -> ${status}"
}

record_setup_failure() {
    local exit_code="$1"
    local line_number="$2"
    local failed_command="$3"
    METAGLENS_STATUS_FILE="${STATUS_FILE}" \
    METAGLENS_EXIT_CODE="${exit_code}" \
    METAGLENS_LINE_NUMBER="${line_number}" \
    METAGLENS_FAILED_COMMAND="${failed_command}" \
    METAGLENS_LOG_FILE="${LOG_DIR}/setup.log" \
    python3 - <<'PY'
import datetime
import json
import os

status_file = os.environ["METAGLENS_STATUS_FILE"]
with open(status_file, "r", encoding="utf-8") as handle:
    data = json.load(handle)

step_data = data["steps"]["00_setup"]
failure = {
    "timestamp": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "attempt": int(step_data.get("attempts", 1)),
    "exit_code": int(os.environ["METAGLENS_EXIT_CODE"]),
    "line": os.environ["METAGLENS_LINE_NUMBER"],
    "command": os.environ["METAGLENS_FAILED_COMMAND"],
    "log_file": os.environ["METAGLENS_LOG_FILE"],
}
step_data["exit_code"] = failure["exit_code"]
step_data["last_failure"] = failure
data["last_failure"] = {"stage": "00_setup", **failure}

with open(status_file, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, ensure_ascii=False)
PY
}

handle_setup_error() {
    local exit_code="${1:-1}"
    local line_number="${2:-unknown}"
    local failed_command="${3:-unknown}"
    trap - ERR
    set +e
    if [[ -f "${STATUS_FILE}" ]]; then
        update_step_status "${STEP_NAME}" "failed"
        record_setup_failure "${exit_code}" "${line_number}" "${failed_command}"
    fi
    log "ERROR: Setup failed with exit code ${exit_code} at line ${line_number}."
    log "ERROR: Failed command: ${failed_command}"
    exit "${exit_code}"
}

check_step_completed() {
    local step="$1"
    if [[ -f "${STATUS_FILE}" ]]; then
        local status
        status=$(python3 -c "import json;f=open('${STATUS_FILE}');d=json.load(f);print(d['steps']['${step}']['status'])")
        if [[ "$status" == "completed" ]]; then
            log "Step ${step} already completed, skipping."
            return 1
        fi
    fi
    return 0
}

check_prerequisite() {
    local step="$1"
    if [[ -f "${STATUS_FILE}" ]]; then
        local status
        status=$(python3 -c "import json;f=open('${STATUS_FILE}');d=json.load(f);print(d['steps']['${step}']['status'])")
        if [[ "$status" != "completed" ]]; then
            log "ERROR: Prerequisite step ${step} not completed (status: ${status}). Run it first."
            exit 1
        fi
    else
        log "ERROR: pipeline_status.json not found. Run 00_setup.sh first."
        exit 1
    fi
}

# ===== Tool-version recording =====
declare -A TOOL_CMDS=(
    [fastp]="fastp --version 2>&1 | head -1"
    [megahit]="megahit --version 2>&1 | head -1"
    [metaspades]="metaspades.py --version 2>&1 | head -1"
    [bowtie2]="bowtie2 --version 2>&1 | head -1"
    [samtools]="samtools --version 2>&1 | head -1"
    [metabat2]="metabat2 --help 2>&1 | grep -i version | head -1"
    [maxbin2]="run_MaxBin.pl -version 2>&1 | head -1"
    [concoct]="concoct --version 2>&1 | head -1"
    [das_tool]="DAS_Tool --version 2>&1 | head -1"
    [checkm2]="checkm2 --version 2>&1 | head -1"
    [drep]="dRep --version 2>&1 | head -1"
    [gtdbtk]="gtdbtk --version 2>&1 | head -1"
    [kraken2]="kraken2 --version 2>&1 | head -1"
    [bracken]="bracken -v 2>&1 | head -1"
    [prokka]="prokka --version 2>&1 | head -1"
    [eggnog-mapper]="emapper.py --version 2>&1 | head -1"
    [seqkit]="seqkit version 2>&1 | head -1"
)

# Usage: record_tool_versions <env_name> <tag> <tool1> [tool2 ...]
record_tool_versions() {
    local env_name="$1"
    local version_tag="$2"
    shift 2
    local tools=("$@")

    eval "$(conda shell.bash hook)"
    conda activate "${env_name}" || { log "ERROR: cannot activate conda env '${env_name}'"; exit 1; }

    {
        echo "## env: ${env_name}"
        for tool in "${tools[@]}"; do
            result=$(eval "${TOOL_CMDS[$tool]}" 2>/dev/null | head -1 || true)
            [[ -n "${result}" ]] || result="version not detected"
            echo "${tool}: ${result} ${version_tag}"
        done
        echo ""
    } >> "${REPORTS_DIR}/tool_versions.txt"
}

# ===== Execution =====
log "======== MetaGLens Setup Start ========"
log "Project: ${PROJECT_NAME}"
log "Work dir: ${WORK_DIR}"
log "Results dir: ${RESULTS_DIR}"
log "Conda mode: ${CONDA_MODE}"
log "Env mapping: qc=${ENV_QC} | binning=${ENV_BINNING} | mag=${ENV_MAG}"

# Python 3 is required for pipeline status management
if ! command -v python3 &>/dev/null; then
    log "WARNING: python3 not found on PATH. Trying to install via conda..."
    conda install -n base -y python 2>/dev/null || true
fi

# Step 1: Initialize pipeline_status.json
log "Initializing pipeline status file..."
init_status_file
trap 'handle_setup_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# Step 2: Initialize run_log.md
log "Initializing run log..."
cat > "${RUN_LOG}" << EOFRUNLOG
# ${PROJECT_NAME} — MetaGLens run log

- **Project**: ${PROJECT_NAME}
- **Work directory**: ${WORK_DIR}
- **Results directory**: ${RESULTS_DIR}
- **Reports directory**: ${REPORTS_DIR}
- **Raw data**: ${RAW_DATA_DIR}
- **Conda environment**: ${CONDA_ENV}（Mode: ${CONDA_MODE}）
- **Started**: $(date '+%Y-%m-%d %H:%M:%S')

## Conda environment information

| Property | Value |
|------|----|
| Base environment name | ${CONDA_ENV} |
| Mode | ${CONDA_MODE} |
| Source | ${CONDA_ORIGIN} |
| Stages 01-03 environment | ${ENV_QC} |
| Stage 04 environment | ${ENV_BINNING} |
| Stages 05-08 environment | ${ENV_MAG} |

## Sample information

| # | Sample ID | R1 file | R2 file |
|---|--------|---------|---------|
EOFRUNLOG

SAMPLE_NUMBER=0
while IFS=$'\t' read -r SAMPLE R1 R2; do
    [[ "${SAMPLE}" == "sample_id" ]] && continue
    SAMPLE_NUMBER=$((SAMPLE_NUMBER + 1))
    echo "| ${SAMPLE_NUMBER} | ${SAMPLE} | ${R1} | ${R2} |" >> "${RUN_LOG}"
done < "${SAMPLE_MANIFEST}"

cat >> "${RUN_LOG}" << EOFRUNLOG2

**Total: ${#SAMPLE_LIST[@]} paired-end samples; naming pattern: ${SAMPLE_PATTERN}**

## Pipeline progress

| Stage | Status | Started | Finished | Script |
|------|------|----------|----------|------|
| 00_setup | 🔄 Running | $(date '+%H:%M') | - | 00_setup.sh |
| 01_qc | ⏳ Pending | - | - | 01_quality_control.sh |
| 02_assembly | ⏳ Pending | - | - | 02_assembly.sh |
| 03_mapping | ⏳ Pending | - | - | 03_read_mapping.sh |
| 04_binning | ⏳ Pending | - | - | 04_binning.sh |
| 05_checkm | ⏳ Pending | - | - | 05_bin_evaluation.sh |
| 06_derep | ⏳ Pending | - | - | 06_dereplication.sh |
| 07_taxonomy | ⏳ Pending | - | - | 07_taxonomy.sh |
| 08_annotation | ⏳ Pending | - | - | 08_annotation.sh |

## Stage summaries

*(Updated automatically after each stage completes)*

EOFRUNLOG2

# Step 3: Conda environment setup
log "========================================"
log "Conda Environment Setup"
log "========================================"

if [[ "${CONDA_MODE}" != "none" ]]; then
    if ! command -v conda &>/dev/null; then
        log "ERROR: Conda is required for CONDA_MODE=${CONDA_MODE}."
        exit 1
    fi
    eval "$(conda shell.bash hook)"
fi

case "${CONDA_MODE}" in
    create)
        log "🔨 Mode: CREATE — 3 grouped envs: ${ENV_QC} / ${ENV_BINNING} / ${ENV_MAG}"
        log "   (Mixing gtdbtk/checkm2/concoct/prokka in one environment often causes dependency conflicts, so tools are grouped by stage)"
        log "   Versions NOT hard-specified — conda resolves dependencies."

        log "Creating '${ENV_QC}' (fastp megahit spades bowtie2 samtools seqkit)..."
        conda create -n "${ENV_QC}" -y -c conda-forge -c bioconda \
            fastp megahit spades bowtie2 samtools seqkit

        log "Creating '${ENV_BINNING}' (metabat2 maxbin2 concoct das_tool)..."
        conda create -n "${ENV_BINNING}" -y -c conda-forge -c bioconda \
            metabat2 maxbin2 concoct das_tool

        log "Creating '${ENV_MAG}' (checkm2 drep gtdbtk kraken2 bracken prokka eggnog-mapper)..."
        conda create -n "${ENV_MAG}" -y -c conda-forge -c bioconda \
            checkm2 drep gtdbtk kraken2 bracken prokka eggnog-mapper

        log "✅ 3 environments created."
        {
            echo "## env: ${ENV_QC}";    conda list -n "${ENV_QC}"
            echo "## env: ${ENV_BINNING}"; conda list -n "${ENV_BINNING}"
            echo "## env: ${ENV_MAG}";   conda list -n "${ENV_MAG}"
        } > "${REPORTS_DIR}/conda_env_packages.tsv"
        log "Package lists → ${REPORTS_DIR}/conda_env_packages.tsv"

        cat > "${REPORTS_DIR}/tool_versions.txt" << EOFVERSIONS
# MetaGLens Tool Versions (recorded: $(date '+%Y-%m-%d %H:%M:%S'))
# Mode: create | Envs: ${ENV_QC} / ${ENV_BINNING} / ${ENV_MAG} (newly created)
# Tags: [new]=freshly installed, [reused]=pre-existing, [updated]=upgraded
EOFVERSIONS
        record_tool_versions "${ENV_QC}" "[new]" fastp megahit metaspades bowtie2 samtools seqkit
        record_tool_versions "${ENV_BINNING}" "[new]" metabat2 maxbin2 concoct das_tool
        record_tool_versions "${ENV_MAG}" "[new]" checkm2 drep gtdbtk kraken2 bracken prokka eggnog-mapper
        ;;

    reuse)
        log "♻️  Mode: REUSE existing environment '${CONDA_ENV}'"
        log "   Origin: ${CONDA_ORIGIN}"

        if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
            log "Missing tools: ${MISSING_TOOLS[*]}"
            conda install -n "${CONDA_ENV}" -y -c conda-forge -c bioconda "${MISSING_TOOLS[@]}"
            log "✅ Missing tools installed."
        else
            log "All tools already present — nothing to install."
        fi

        conda list -n "${CONDA_ENV}" > "${REPORTS_DIR}/conda_env_packages.tsv"
        cat > "${REPORTS_DIR}/tool_versions.txt" << EOFVERSIONS
# MetaGLens Tool Versions (recorded: $(date '+%Y-%m-%d %H:%M:%S'))
# Mode: reuse | Environment: ${CONDA_ENV} (reused from ${CONDA_ORIGIN})
# Tags: [new]=freshly installed, [reused]=pre-existing, [updated]=upgraded
EOFVERSIONS
        record_tool_versions "${CONDA_ENV}" "[reused]" \
            fastp megahit metaspades bowtie2 samtools seqkit \
            metabat2 maxbin2 concoct das_tool \
            checkm2 drep gtdbtk kraken2 bracken prokka eggnog-mapper
        for tool in ${MISSING_TOOLS[@]+"${MISSING_TOOLS[@]}"}; do
            sed -i "s|^${tool}: \(.*\) \[reused\]$|${tool}: \1 [new]|" \
                "${REPORTS_DIR}/tool_versions.txt"
        done
        ;;

    reuse_and_update)
        log "🔄 Mode: REUSE & UPDATE environment '${CONDA_ENV}'"
        log "   Origin: ${CONDA_ORIGIN}"

        if [[ ${#UPDATE_TOOLS[@]} -gt 0 ]]; then
            log "Updating: ${UPDATE_TOOLS[*]}"
            for tool in "${UPDATE_TOOLS[@]}"; do
                log "  Updating ${tool}..."
                conda update -n "${CONDA_ENV}" -y -c conda-forge -c bioconda "${tool}" 2>/dev/null || \
                    log "  ⚠️  ${tool} update skipped"
            done
        fi
        if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
            log "Missing tools: ${MISSING_TOOLS[*]}"
            conda install -n "${CONDA_ENV}" -y -c conda-forge -c bioconda "${MISSING_TOOLS[@]}"
        fi

        conda list -n "${CONDA_ENV}" > "${REPORTS_DIR}/conda_env_packages.tsv"
        cat > "${REPORTS_DIR}/tool_versions.txt" << EOFVERSIONS
# MetaGLens Tool Versions (recorded: $(date '+%Y-%m-%d %H:%M:%S'))
# Mode: reuse_and_update | Environment: ${CONDA_ENV} (reused from ${CONDA_ORIGIN}, with updates)
# Tags: [new]=freshly installed, [reused]=pre-existing, [updated]=upgraded
EOFVERSIONS
        record_tool_versions "${CONDA_ENV}" "[reused]" \
            fastp megahit metaspades bowtie2 samtools seqkit \
            metabat2 maxbin2 concoct das_tool \
            checkm2 drep gtdbtk kraken2 bracken prokka eggnog-mapper

        # Retag tools updated in this run as [updated]
        for tool in ${UPDATE_TOOLS[@]+"${UPDATE_TOOLS[@]}"}; do
            sed -i "s|^${tool}: \(.*\) \[reused\]$|${tool}: \1 [updated]|" "${REPORTS_DIR}/tool_versions.txt"
        done
        for tool in ${MISSING_TOOLS[@]+"${MISSING_TOOLS[@]}"}; do
            sed -i "s|^${tool}: \(.*\) \[reused\]$|${tool}: \1 [new]|" \
                "${REPORTS_DIR}/tool_versions.txt"
        done
        ;;

    none)
        log "Mode: NONE — use tools already available on PATH."
        printf '# Conda package inventory not available (CONDA_MODE=none)\n' \
            > "${REPORTS_DIR}/conda_env_packages.tsv"
        cat > "${REPORTS_DIR}/tool_versions.txt" << EOFVERSIONS
# MetaGLens Tool Versions (recorded: $(date '+%Y-%m-%d %H:%M:%S'))
# Mode: none | Tools resolved from PATH
EOFVERSIONS
        for tool in "${!TOOL_CMDS[@]}"; do
            result=$(eval "${TOOL_CMDS[$tool]}" 2>/dev/null | head -1 || true)
            [[ -n "${result}" ]] || result="not detected"
            echo "${tool}: ${result} [reused]" >> "${REPORTS_DIR}/tool_versions.txt"
        done
        ;;

    *)
        log "ERROR: Unknown CONDA_MODE '${CONDA_MODE}'"
        exit 1
        ;;
esac

log "Tool versions → ${REPORTS_DIR}/tool_versions.txt"

# Step 4: Database setup
log "========================================"
log "Database Setup (dir: ${DB_DIR})"
log "========================================"
mkdir -p "${DB_DIR}"

if [[ "${DOWNLOAD_DBS}" == "yes" ]]; then
    conda activate "${ENV_MAG}" 2>/dev/null || true

    # CheckM2 (~3 GB)
    if [[ ! -d "${DB_DIR}/checkm2" || -z "$(ls -A "${DB_DIR}/checkm2" 2>/dev/null)" ]]; then
        log "Downloading CheckM2 database → ${DB_DIR}/checkm2 ..."
        mkdir -p "${DB_DIR}/checkm2"
        checkm2 database --download --path "${DB_DIR}/checkm2" || \
            log "⚠️  CheckM2 DB download failed — run this command manually later: checkm2 database --download --path ${DB_DIR}/checkm2"
    else
        log "CheckM2 DB exists — skipping."
    fi

    # eggNOG (~40 GB)
    if [[ ! -d "${DB_DIR}/eggnog" || -z "$(ls -A "${DB_DIR}/eggnog" 2>/dev/null)" ]]; then
        log "Downloading eggNOG database → ${DB_DIR}/eggnog ..."
        download_eggnog_data.py -y --data_dir "${DB_DIR}/eggnog" || \
            log "⚠️  eggNOG download failed — run this command manually later: download_eggnog_data.py -y --data_dir ${DB_DIR}/eggnog"
    else
        log "eggNOG DB exists — skipping."
    fi

    # Kraken2 standard（~100 GB，building may take hours; a prebuilt index can also be used）
    if [[ ! -d "${DB_DIR}/kraken2_standard" || -z "$(ls -A "${DB_DIR}/kraken2_standard" 2>/dev/null)" ]]; then
        log "Building Kraken2 standard database → ${DB_DIR}/kraken2_standard (large, may take hours) ..."
        kraken2-build --standard --db "${DB_DIR}/kraken2_standard" --threads "${THREADS}" || \
            log "⚠️  Kraken2 build failed — download a prebuilt index from https://benlangmead.github.io/aws-indexes/k2"
    else
        log "Kraken2 DB exists — skipping."
    fi

    # GTDB-Tk reference package (~110 GB unpacked): resolve the package from the latest GTDB release
    if [[ ! -d "${DB_DIR}/gtdbtk" || -z "$(ls -A "${DB_DIR}/gtdbtk" 2>/dev/null)" ]]; then
        log "Downloading GTDB-Tk reference package (~110 GB unpacked) ..."
        mkdir -p "${DB_DIR}/gtdbtk"
        GTDB_PKG=$(curl -fsSL "https://data.gtdb.ecogenomic.org/releases/latest/auxillary_files/gtdbtk_package/" 2>/dev/null \
            | grep -oE 'gtdbtk_r[0-9]+_data\.tar\.gz' | head -1 || true)
        if [[ -n "${GTDB_PKG}" ]]; then
            if curl -fSL "https://data.gtdb.ecogenomic.org/releases/latest/auxillary_files/gtdbtk_package/${GTDB_PKG}" \
                    -o "${DB_DIR}/gtdbtk/${GTDB_PKG}" && \
               tar -xzf "${DB_DIR}/gtdbtk/${GTDB_PKG}" -C "${DB_DIR}/gtdbtk" --strip-components=1; then
                rm -f "${DB_DIR}/gtdbtk/${GTDB_PKG}"
                log "✅ GTDB-Tk reference package ready → ${DB_DIR}/gtdbtk"
            else
                log "⚠️  GTDB download/extract failed — manual download: https://ecogenomics.github.io/GTDBTk/installing/index.html"
            fi
        else
            log "⚠️  Could not resolve the GTDB package name; download and extract it manually to ${DB_DIR}/gtdbtk"
        fi
    else
        log "GTDB DB exists — skipping."
    fi
else
    log "DOWNLOAD_DBS=no — skip database downloads. Prepare these databases and provide their paths to the relevant stages："
    log "  CheckM2  : checkm2 database --download --path ${DB_DIR}/checkm2"
    log "  GTDB-Tk  : download and extract the reference package to ${DB_DIR}/gtdbtk（https://ecogenomics.github.io/GTDBTk/，~110 GB）"
    log "  Kraken2  : kraken2-build --standard --db ${DB_DIR}/kraken2_standard，or download a prebuilt index"
    log "  eggNOG   : download_eggnog_data.py -y --data_dir ${DB_DIR}/eggnog"
fi

# ===== Conda environmentSummary =====
log ""
log "======== Conda Environment Summary ========"
case "${CONDA_MODE}" in
    create)  log "🔨 Mode: CREATE | Envs: ${ENV_QC} / ${ENV_BINNING} / ${ENV_MAG}" ;;
    reuse)   log "♻️  Mode: REUSE  | Env: ${CONDA_ENV} | Source: ${CONDA_ORIGIN}" ;;
    reuse_and_update) log "🔄 Mode: UPDATE | Env: ${CONDA_ENV} | Source: ${CONDA_ORIGIN}" ;;
    none)    log "Mode: NONE | Tools resolved from PATH" ;;
esac
log "Packages  : ${REPORTS_DIR}/conda_env_packages.tsv"
log "Versions  : ${REPORTS_DIR}/tool_versions.txt"
log "Run log   : ${RUN_LOG}"
log "Databases : ${DB_DIR} (DOWNLOAD_DBS=${DOWNLOAD_DBS})"
log "============================================"

# Step 5: Completion
update_step_status "00_setup" "completed"
sed -i "s/| 00_setup |[^|]*|[^|]*|[^|]*|/| 00_setup | ✅ Completion | - | $(date '+%H:%M') |/" "${RUN_LOG}"

log "======== MetaGLens Setup Complete ========"
log "All results in: ${RESULTS_DIR}/"
echo ""
echo "Next steps:"
echo "  1. cd ${RESULTS_DIR}"
echo "  2. bash 01_quality_control.sh   (the script activates the required Conda environment)"
echo "  3. View run log: cat ${RUN_LOG}"
