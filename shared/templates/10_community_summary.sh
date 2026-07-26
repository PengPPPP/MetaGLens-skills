#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_community
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --output=metaglens_results/reports/logs/10_community_%j.log

set -euo pipefail

# ===== Load pipeline utilities =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "${SCRIPT_DIR}/pipeline_utils.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/pipeline_utils.sh is required." >&2
    exit 1
fi
source "${SCRIPT_DIR}/pipeline_utils.sh"

# ===== Parameters =====
# Build cross-sample community summary tables and topN subsets. The abundance
# source is chosen automatically from the route:
#   - Kraken2/Bracken relative abundance  (read-based / contig-based routes)
#   - GTDB-Tk taxonomic composition       (MAG route; representative-genome counts)
# The chosen source is recorded in SOURCE.txt and stated at delivery.
STEP_NAME="10_community"
WORK_DIR="{{WORK_DIR}}"
# Space-separated topN cut-offs to emit (e.g., "10 15 20").
TOP_LEVELS="{{TOP_LEVELS}}"
# Preferred taxonomic level for Bracken tables: S (species) by default.
TAX_LEVEL="{{TAX_LEVEL}}"
SAMPLES=({{SAMPLE_LIST}})

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
TAX_DIR="${RESULTS_DIR}/07_taxonomy"
CONTIG_TAX_DIR="${RESULTS_DIR}/09_contig/taxonomy"
MAG_ABUND_DIR="${RESULTS_DIR}/mag_abundance"
OUTPUT_DIR="${RESULTS_DIR}/10_community"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
LOG_FILE="${LOG_DIR}/10_community.log"

# ===== Resume and status checks =====
log_step "MetaGLens Community Summary — 10_community_summary.sh"
init_status_if_missing

if ! check_step_completed "${STEP_NAME}"; then
    log "Skipping community summary (already completed)."
    exit 0
fi

update_step_status "${STEP_NAME}" "running"
enable_step_failure_trap

mkdir -p "${OUTPUT_DIR}"
START_TIME=$(date '+%H:%M')

# Read the analysis basis recorded at setup to guide source selection.
ANALYSIS_BASIS=$(python3 -c "import json;print(json.load(open('${STATUS_FILE}')).get('analysis_basis','mag'))" 2>/dev/null || echo "mag")
log "Analysis basis: ${ANALYSIS_BASIS}"

# ===== Detect available abundance sources =====
shopt -s nullglob
BRACKEN_FILES=("${TAX_DIR}/kraken2/"*_bracken.out)
KRAKEN_READ_REPORTS=("${TAX_DIR}/kraken2/"*_report.txt)
CONTIG_KRAKEN_REPORTS=("${CONTIG_TAX_DIR}/"*_contig_report.txt)
GTDB_SUMMARIES=("${TAX_DIR}/gtdbtk/gtdbtk.bac120.summary.tsv" "${TAX_DIR}/gtdbtk/gtdbtk.ar53.summary.tsv")
MAG_RELABUND="${MAG_ABUND_DIR}/mag_relative_abundance.tsv"
shopt -u nullglob

SOURCE=""
if [[ ${#BRACKEN_FILES[@]} -gt 0 ]]; then
    SOURCE="bracken"
elif [[ -f "${MAG_RELABUND}" && ${#GTDB_SUMMARIES[@]} -gt 0 ]]; then
    SOURCE="mag_coverage"
elif [[ ${#GTDB_SUMMARIES[@]} -gt 0 ]]; then
    SOURCE="gtdbtk"
elif [[ ${#CONTIG_KRAKEN_REPORTS[@]} -gt 0 ]]; then
    SOURCE="contig_kraken"
elif [[ ${#KRAKEN_READ_REPORTS[@]} -gt 0 ]]; then
    SOURCE="kraken_report"
else
    log "ERROR: No taxonomy outputs found for a community table (looked for Bracken, MAG abundance + GTDB-Tk, GTDB-Tk, or Kraken2 reports)."
    exit 1
fi
log "Selected abundance source: ${SOURCE}"

MATRIX="${OUTPUT_DIR}/community_matrix.tsv"

case "${SOURCE}" in
    bracken)
        SOURCE_LABEL="Kraken2/Bracken read-based relative abundance (fraction_total_reads, level ${TAX_LEVEL})"
        METAGLENS_MATRIX="${MATRIX}" \
        METAGLENS_TAX_LEVEL="${TAX_LEVEL}" \
        METAGLENS_BRACKEN_DIR="${TAX_DIR}/kraken2" \
        python3 - <<'PY'
import glob, os
matrix = os.environ["METAGLENS_MATRIX"]
level = os.environ["METAGLENS_TAX_LEVEL"]
bdir = os.environ["METAGLENS_BRACKEN_DIR"]
files = sorted(glob.glob(os.path.join(bdir, "*_bracken.out")))
abund = {}
samples = []
for path in files:
    sample = os.path.basename(path).replace("_bracken.out", "")
    samples.append(sample)
    with open(path) as fh:
        header = fh.readline().rstrip("\n").split("\t")
        # Bracken columns: name, taxonomy_id, taxonomy_lvl, kraken_assigned_reads,
        #                  added_reads, new_est_reads, fraction_total_reads
        try:
            name_i = header.index("name")
            lvl_i = header.index("taxonomy_lvl")
            frac_i = header.index("fraction_total_reads")
        except ValueError:
            name_i, lvl_i, frac_i = 0, 2, 6
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) <= frac_i:
                continue
            if level and p[lvl_i] != level:
                continue
            abund.setdefault(p[name_i], {})[sample] = p[frac_i]
with open(matrix, "w") as fh:
    fh.write("taxon\t" + "\t".join(samples) + "\n")
    for taxon in sorted(abund, key=lambda t: -sum(float(abund[t].get(s, 0) or 0) for s in samples)):
        row = [abund[taxon].get(s, "0") for s in samples]
        fh.write(taxon + "\t" + "\t".join(row) + "\n")
print("Wrote community matrix from %d Bracken files." % len(files))
PY
        ;;

    gtdbtk)
        SOURCE_LABEL="GTDB-Tk taxonomic composition (representative-genome counts per taxon; not read/coverage relative abundance)"
        METAGLENS_MATRIX="${MATRIX}" \
        METAGLENS_GTDB_DIR="${TAX_DIR}/gtdbtk" \
        python3 - <<'PY'
import os
matrix = os.environ["METAGLENS_MATRIX"]
gdir = os.environ["METAGLENS_GTDB_DIR"]
counts = {}
for fname in ("gtdbtk.bac120.summary.tsv", "gtdbtk.ar53.summary.tsv"):
    path = os.path.join(gdir, fname)
    if not os.path.isfile(path):
        continue
    with open(path) as fh:
        fh.readline()  # header
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) < 2:
                continue
            classification = p[1] if p[1] else "Unclassified"
            counts[classification] = counts.get(classification, 0) + 1
with open(matrix, "w") as fh:
    fh.write("taxon\tMAG_count\n")
    for taxon in sorted(counts, key=lambda t: -counts[t]):
        fh.write("%s\t%d\n" % (taxon, counts[taxon]))
print("Wrote MAG taxonomic composition for %d taxa." % len(counts))
PY
        ;;

    mag_coverage)
        SOURCE_LABEL="MAG relative abundance (reads mapped to dereplicated MAGs) aggregated by GTDB-Tk taxonomy, per sample (%)"
        METAGLENS_MATRIX="${MATRIX}" \
        METAGLENS_MAG_RELABUND="${MAG_RELABUND}" \
        METAGLENS_GTDB_DIR="${TAX_DIR}/gtdbtk" \
        python3 - <<'PY'
import os
matrix = os.environ["METAGLENS_MATRIX"]
relabund = os.environ["METAGLENS_MAG_RELABUND"]
gdir = os.environ["METAGLENS_GTDB_DIR"]

# Map MAG (user_genome) -> classification string from GTDB-Tk summaries.
mag_tax = {}
for fname in ("gtdbtk.bac120.summary.tsv", "gtdbtk.ar53.summary.tsv"):
    path = os.path.join(gdir, fname)
    if not os.path.isfile(path):
        continue
    with open(path) as fh:
        fh.readline()
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) < 2:
                continue
            mag_tax[p[0]] = p[1] if p[1] else "Unclassified"

# Read the MAG x sample relative abundance matrix.
with open(relabund) as fh:
    header = fh.readline().rstrip("\n").split("\t")
    samples = header[1:]
    taxon_abund = {}
    for line in fh:
        p = line.rstrip("\n").split("\t")
        if len(p) < 2:
            continue
        mag = p[0]
        taxon = mag_tax.get(mag, "Unclassified")
        vals = taxon_abund.setdefault(taxon, [0.0] * len(samples))
        for i in range(len(samples)):
            try:
                vals[i] += float(p[i + 1])
            except (ValueError, IndexError):
                pass

with open(matrix, "w") as fh:
    fh.write("taxon\t" + "\t".join(samples) + "\n")
    for taxon in sorted(taxon_abund, key=lambda t: -sum(taxon_abund[t])):
        row = ["%.4f" % v for v in taxon_abund[taxon]]
        fh.write(taxon + "\t" + "\t".join(row) + "\n")
print("Wrote MAG-coverage community matrix for %d taxa across %d samples." % (len(taxon_abund), len(samples)))
PY
        ;;

    contig_kraken|kraken_report)
        if [[ "${SOURCE}" == "contig_kraken" ]]; then
            SOURCE_LABEL="Kraken2 contig-based composition (per-taxon clade fraction from contig reports, level ${TAX_LEVEL})"
            REPORT_DIR="${CONTIG_TAX_DIR}"
            REPORT_GLOB="*_contig_report.txt"
        else
            SOURCE_LABEL="Kraken2 read-based composition (per-taxon clade fraction from reports, level ${TAX_LEVEL})"
            REPORT_DIR="${TAX_DIR}/kraken2"
            REPORT_GLOB="*_report.txt"
        fi
        METAGLENS_MATRIX="${MATRIX}" \
        METAGLENS_TAX_LEVEL="${TAX_LEVEL}" \
        METAGLENS_REPORT_DIR="${REPORT_DIR}" \
        METAGLENS_REPORT_GLOB="${REPORT_GLOB}" \
        python3 - <<'PY'
import glob, os
matrix = os.environ["METAGLENS_MATRIX"]
level = os.environ["METAGLENS_TAX_LEVEL"] or "S"
rdir = os.environ["METAGLENS_REPORT_DIR"]
rglob = os.environ["METAGLENS_REPORT_GLOB"]
files = sorted(glob.glob(os.path.join(rdir, rglob)))
abund = {}
samples = []
for path in files:
    base = os.path.basename(path)
    sample = base.replace("_contig_report.txt", "").replace("_report.txt", "")
    samples.append(sample)
    with open(path) as fh:
        # Kraken2 report: pct, clade_reads, taxon_reads, rank_code, taxid, name
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) < 6:
                continue
            pct, rank, name = p[0].strip(), p[3].strip(), p[5].strip()
            if rank != level:
                continue
            abund.setdefault(name, {})[sample] = pct
with open(matrix, "w") as fh:
    fh.write("taxon\t" + "\t".join(samples) + "\n")
    for taxon in sorted(abund, key=lambda t: -sum(float(abund[t].get(s, 0) or 0) for s in samples)):
        row = [abund[taxon].get(s, "0") for s in samples]
        fh.write(taxon + "\t" + "\t".join(row) + "\n")
print("Wrote community matrix from %d Kraken2 reports." % len(files))
PY
        ;;
esac

# Record the source used (for delivery transparency).
echo "${SOURCE_LABEL}" > "${OUTPUT_DIR}/SOURCE.txt"
log "Community matrix: ${MATRIX}"
log "Source: ${SOURCE_LABEL}"

# ===== Emit topN subsets =====
# Rank rows by the sum of their numeric columns (relative abundance or count).
for N in ${TOP_LEVELS}; do
    TOP_OUT="${OUTPUT_DIR}/community_top${N}.tsv"
    METAGLENS_MATRIX="${MATRIX}" METAGLENS_TOP_OUT="${TOP_OUT}" METAGLENS_N="${N}" python3 - <<'PY'
import os
matrix = os.environ["METAGLENS_MATRIX"]
out = os.environ["METAGLENS_TOP_OUT"]
n = int(os.environ["METAGLENS_N"])
with open(matrix) as fh:
    header = fh.readline()
    rows = []
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        vals = []
        for v in parts[1:]:
            try:
                vals.append(float(v))
            except ValueError:
                vals.append(0.0)
        rows.append((sum(vals), line))
rows.sort(key=lambda r: -r[0])
with open(out, "w") as fh:
    fh.write(header)
    for _, line in rows[:n]:
        fh.write(line)
PY
    log "Wrote top${N} table: ${TOP_OUT}"
done

# ===== Summary =====
NUM_TAXA=$(( $(wc -l < "${MATRIX}") - 1 ))
log_step "Community Summary"
log "Total taxa: ${NUM_TAXA}"
log "topN tables: ${TOP_LEVELS}"

# ===== Update status and run log =====
update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"
    cat >> "${RUN_LOG}" << EOFRUNLOGCOM

### 10 Community summary tables
- **Abundance source**: ${SOURCE_LABEL}
- **Total taxa**: ${NUM_TAXA}
- **topN tables**: ${TOP_LEVELS}
- **Output**: ${OUTPUT_DIR}/ (community_matrix.tsv, community_top*.tsv, SOURCE.txt)
- **Detailed log**: logs/10_community.log

EOFRUNLOGCOM
fi

log_step "Community summary completed"
echo "Next step: bash 11_delivery.sh"
