#!/bin/bash
#SBATCH --job-name={{PROJECT_NAME}}_delivery
#SBATCH --cpus-per-task={{THREADS}}
#SBATCH --output=metaglens_results/reports/logs/11_delivery_%j.log

set -euo pipefail

# ===== Load pipeline utilities =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "${SCRIPT_DIR}/pipeline_utils.sh" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/pipeline_utils.sh is required." >&2
    exit 1
fi
source "${SCRIPT_DIR}/pipeline_utils.sh"

# ===== Parameters =====
# Assemble an analysis-ready delivery package and a data dictionary that
# explains every delivered file. Packaging into a tarball is optional.
STEP_NAME="11_delivery"
WORK_DIR="{{WORK_DIR}}"
PROJECT_NAME="{{PROJECT_NAME}}"
RAW_DATA_DIR="{{RAW_DATA_DIR}}"
# Set to "yes" to also create a .tar.gz of the delivery directory.
DO_TARBALL="{{DO_TARBALL}}"

# ===== Paths =====
RESULTS_DIR="${WORK_DIR}/metaglens_results"
REPORTS_DIR="${RESULTS_DIR}/reports"
LOG_DIR="${REPORTS_DIR}/logs"
DELIVERY_DIR="${RESULTS_DIR}/delivery"

STATUS_FILE="${RESULTS_DIR}/pipeline_status.json"
RUN_LOG="${REPORTS_DIR}/run_log.md"
LOG_FILE="${LOG_DIR}/11_delivery.log"

# ===== Resume and status checks =====
log_step "MetaGLens Delivery — 11_delivery.sh"
init_status_if_missing

if ! check_step_completed "${STEP_NAME}"; then
    log "Skipping delivery (already completed)."
    exit 0
fi

update_step_status "${STEP_NAME}" "running"
enable_step_failure_trap

ANALYSIS_BASIS=$(python3 -c "import json;print(json.load(open('${STATUS_FILE}')).get('analysis_basis','mag'))" 2>/dev/null || echo "mag")
ROUTE_NAME=$(python3 -c "import json;print(json.load(open('${STATUS_FILE}')).get('route_name','custom'))" 2>/dev/null || echo "custom")
log "Analysis basis: ${ANALYSIS_BASIS}; route: ${ROUTE_NAME}"

# ===== Build the delivery layout =====
mkdir -p "${DELIVERY_DIR}"/{genomes,tables,annotations,taxonomy,contig,community}
START_TIME=$(date '+%H:%M')

# Copy a file/glob into a destination when present; log what was delivered.
deliver() {
    local dest="$1"; shift
    local pattern
    for pattern in "$@"; do
        shopt -s nullglob
        local matches=(${pattern})
        shopt -u nullglob
        local m
        for m in "${matches[@]}"; do
            [[ -e "${m}" ]] || continue
            cp -r "${m}" "${dest}/"
            log "  delivered: ${m} -> ${dest}/"
        done
    done
}

# --- MAG-route artifacts ---
if [[ "${ANALYSIS_BASIS}" == "mag" || "${ANALYSIS_BASIS}" == "both" ]]; then
    deliver "${DELIVERY_DIR}/genomes" "${RESULTS_DIR}/06_derep/dereplicated_genomes/"*.fa \
        "${RESULTS_DIR}/06_derep/dereplicated_genomes/"*.fna "${RESULTS_DIR}/06_derep/dereplicated_genomes/"*.fasta
    deliver "${DELIVERY_DIR}/tables" "${RESULTS_DIR}/05_checkm/quality_report.tsv" \
        "${RESULTS_DIR}/05_checkm/quality_report_filtered.tsv"
    deliver "${DELIVERY_DIR}/tables" "${RESULTS_DIR}/mag_abundance/mag_abundance_mean_depth.tsv" \
        "${RESULTS_DIR}/mag_abundance/mag_relative_abundance.tsv"
    deliver "${DELIVERY_DIR}/taxonomy" "${RESULTS_DIR}/07_taxonomy/gtdbtk/gtdbtk.bac120.summary.tsv" \
        "${RESULTS_DIR}/07_taxonomy/gtdbtk/gtdbtk.ar53.summary.tsv"
    deliver "${DELIVERY_DIR}/annotations" "${RESULTS_DIR}/08_annotation/eggnog/eggnog_results.emapper.annotations"
fi

# --- Contig-route artifacts ---
if [[ "${ANALYSIS_BASIS}" == "contig" || "${ANALYSIS_BASIS}" == "both" ]]; then
    deliver "${DELIVERY_DIR}/contig" "${RESULTS_DIR}/09_contig/genes/"*_proteins.faa \
        "${RESULTS_DIR}/09_contig/genes/"*_genes.gff \
        "${RESULTS_DIR}/09_contig/abundance/contig_coverage.tsv"
    deliver "${DELIVERY_DIR}/annotations" "${RESULTS_DIR}/09_contig/eggnog/eggnog_results.emapper.annotations"
    deliver "${DELIVERY_DIR}/taxonomy" "${RESULTS_DIR}/09_contig/taxonomy/"*_contig_report.txt
fi

# --- Community tables (all routes) ---
deliver "${DELIVERY_DIR}/community" "${RESULTS_DIR}/10_community/community_matrix.tsv" \
    "${RESULTS_DIR}/10_community/community_top"*.tsv "${RESULTS_DIR}/10_community/SOURCE.txt"

# --- Provenance ---
deliver "${DELIVERY_DIR}/tables" "${REPORTS_DIR}/tool_versions.txt"

COMMUNITY_SOURCE="(community summary not produced)"
[[ -f "${RESULTS_DIR}/10_community/SOURCE.txt" ]] && COMMUNITY_SOURCE=$(cat "${RESULTS_DIR}/10_community/SOURCE.txt")

# ===== Generate the data dictionary =====
log_step "Generating DATA_DICTIONARY.md"
METAGLENS_DELIVERY_DIR="${DELIVERY_DIR}" \
METAGLENS_PROJECT_NAME="${PROJECT_NAME}" \
METAGLENS_ROUTE="${ROUTE_NAME}" \
METAGLENS_BASIS="${ANALYSIS_BASIS}" \
METAGLENS_COMMUNITY_SOURCE="${COMMUNITY_SOURCE}" \
python3 - <<'PY'
import datetime, os

root = os.environ["METAGLENS_DELIVERY_DIR"]
project = os.environ["METAGLENS_PROJECT_NAME"]
route = os.environ["METAGLENS_ROUTE"]
basis = os.environ["METAGLENS_BASIS"]
community_source = os.environ["METAGLENS_COMMUNITY_SOURCE"]

# Per-file / per-pattern descriptions keyed by a matching rule on the relative path.
def describe(rel):
    name = os.path.basename(rel)
    if rel.startswith("genomes/"):
        return "Dereplicated representative genome (MAG), nucleotide FASTA."
    if name == "quality_report.tsv":
        return "CheckM2 quality report for all bins: completeness, contamination, model used."
    if name == "quality_report_filtered.tsv":
        return "CheckM2 report filtered to bins passing the completeness/contamination thresholds."
    if name == "mag_abundance_mean_depth.tsv":
        return "MAG x sample length-weighted mean coverage depth (reads mapped to dereplicated MAGs)."
    if name == "mag_relative_abundance.tsv":
        return "MAG x sample relative abundance (%), column-normalized from mean coverage depth."
    if name.startswith("gtdbtk.") and name.endswith(".summary.tsv"):
        return "GTDB-Tk classification summary; column 2 is the assigned taxonomy string."
    if name == "eggnog_results.emapper.annotations":
        return "eggNOG-mapper functional annotations (COG/KEGG/GO/EC etc.) per predicted protein."
    if name.endswith("_proteins.faa"):
        return "Prodigal-predicted protein sequences for a contig set (unit-labeled)."
    if name.endswith("_genes.gff"):
        return "Prodigal gene coordinates (GFF) for a contig set."
    if name == "contig_coverage.tsv":
        return "Contig x sample mean-coverage matrix (abundance) from read mapping depth."
    if name.endswith("_contig_report.txt"):
        return "Kraken2 contig taxonomy report (clade fractions per taxon)."
    if name == "community_matrix.tsv":
        return "Full cross-sample community table (taxon x sample). See SOURCE.txt for the abundance source."
    if name.startswith("community_top") and name.endswith(".tsv"):
        n = name.replace("community_top", "").replace(".tsv", "")
        return "Top %s most abundant taxa subset of the community table." % n
    if name == "SOURCE.txt":
        return "States which abundance source was used to build the community tables."
    if name == "tool_versions.txt":
        return "Recorded software versions used in this run (provenance)."
    return "Delivered analysis file."

lines = []
lines.append("# %s — MetaGLens delivery data dictionary" % project)
lines.append("")
lines.append("- Route: `%s`" % route)
lines.append("- Analysis basis: `%s`" % basis)
lines.append("- Community abundance source: %s" % community_source)
lines.append("- Generated: %s" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
lines.append("")
lines.append("This package contains analysis-ready outputs. Each file below is")
lines.append("described with its purpose so it can be used directly for downstream")
lines.append("statistics and figures.")
lines.append("")

entries = []
for dirpath, _dirs, files in os.walk(root):
    for f in sorted(files):
        if f == "DATA_DICTIONARY.md":
            continue
        full = os.path.join(dirpath, f)
        rel = os.path.relpath(full, root)
        size = os.path.getsize(full)
        entries.append((rel, size))

entries.sort()
lines.append("| File | Size (bytes) | Description |")
lines.append("|---|---|---|")
if not entries:
    lines.append("| (none) | 0 | No artifacts were available to deliver for this route. |")
for rel, size in entries:
    lines.append("| `%s` | %d | %s |" % (rel, size, describe(rel)))
lines.append("")

with open(os.path.join(root, "DATA_DICTIONARY.md"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
print("Data dictionary written with %d entries." % len(entries))
PY

# ===== Generate an interactive HTML report for the end user =====
# report.html is self-contained (logo embedded) and populated from the real
# delivered tables. The logo data URI is read from report_logo.b64 when present.
log_step "Generating report.html"
LOGO_FILE="${SCRIPT_DIR}/report_logo.b64"
METAGLENS_DELIVERY_DIR="${DELIVERY_DIR}" \
METAGLENS_STATUS_FILE="${STATUS_FILE}" \
METAGLENS_PROJECT="${PROJECT_NAME}" \
METAGLENS_ROUTE="${ROUTE_NAME}" \
METAGLENS_BASIS="${ANALYSIS_BASIS}" \
METAGLENS_RAWDATA="${RAW_DATA_DIR}" \
METAGLENS_COMMUNITY_SOURCE="${COMMUNITY_SOURCE}" \
METAGLENS_LOGO_FILE="${LOGO_FILE}" \
python3 - <<'PY'
import json, os, datetime, html as _h

DELIVERY = os.environ["METAGLENS_DELIVERY_DIR"]
STATUS = os.environ["METAGLENS_STATUS_FILE"]
PROJECT = os.environ["METAGLENS_PROJECT"]
ROUTE = os.environ["METAGLENS_ROUTE"]
BASIS = os.environ["METAGLENS_BASIS"]
RAWDATA = os.environ.get("METAGLENS_RAWDATA", "")
COMMUNITY_SOURCE = os.environ.get("METAGLENS_COMMUNITY_SOURCE", "")
LOGO_FILE = os.environ.get("METAGLENS_LOGO_FILE", "")

def read_tsv(path):
    with open(path) as fh:
        return [ln.rstrip("\n").split("\t") for ln in fh]

def to_floats(cells):
    out = []
    for v in cells:
        try:
            out.append(float(v))
        except ValueError:
            out.append(0.0)
    return out

samples, parallel = [], ""
try:
    d = json.load(open(STATUS))
    samples = d.get("samples", [])
    p = d.get("parallel", {})
    parallel = "%s jobs x %s threads (%s)" % (
        p.get("parallel_jobs", "?"), p.get("threads_per_job", "?"), p.get("exec_env", "local"))
except Exception:
    pass

taxa, comm_samples = [], []
cm = os.path.join(DELIVERY, "community", "community_matrix.tsv")
if os.path.isfile(cm):
    rows = read_tsv(cm)
    if rows:
        comm_samples = rows[0][1:]
        for r in rows[1:]:
            if len(r) >= 2:
                taxa.append([r[0], to_floats(r[1:])])

mag_ab, mag_samples = {}, []
ma = os.path.join(DELIVERY, "tables", "mag_relative_abundance.tsv")
if os.path.isfile(ma):
    rows = read_tsv(ma)
    if rows:
        mag_samples = rows[0][1:]
        for r in rows[1:]:
            if len(r) >= 2:
                mag_ab[r[0]] = dict(zip(mag_samples, to_floats(r[1:])))

run_samples = comm_samples or mag_samples or samples

checkm = {}
q = os.path.join(DELIVERY, "tables", "quality_report_filtered.tsv")
if os.path.isfile(q):
    for r in read_tsv(q)[1:]:
        if len(r) >= 3:
            try:
                checkm[r[0]] = (float(r[1]), float(r[2]))
            except ValueError:
                pass

mags = []
for name in (set(checkm) | set(mag_ab)):
    comp, cont = checkm.get(name, (None, None))
    vals = [mag_ab.get(name, {}).get(s, 0.0) for s in run_samples]
    mags.append([name, comp, cont, vals])
mags.sort(key=lambda m: (-sum(m[3]), m[0]))

# Realign community rows to run_samples order if needed.
if taxa and comm_samples and comm_samples != run_samples:
    idx = [comm_samples.index(s) if s in comm_samples else None for s in run_samples]
    taxa = [[t[0], [(t[1][i] if (i is not None and i < len(t[1])) else 0.0) for i in idx]] for t in taxa]

def describe(rel):
    n = os.path.basename(rel)
    if rel.startswith("genomes/"): return "Dereplicated representative genome (MAG), FASTA."
    if n == "quality_report_filtered.tsv": return "CheckM2 report for retained MAGs (completeness/contamination)."
    if n == "quality_report.tsv": return "CheckM2 quality report for all bins."
    if n == "mag_relative_abundance.tsv": return "MAG x sample relative abundance (%)."
    if n == "mag_abundance_mean_depth.tsv": return "MAG x sample mean coverage depth."
    if n.startswith("gtdbtk.") and n.endswith(".summary.tsv"): return "GTDB-Tk taxonomy summary."
    if n == "eggnog_results.emapper.annotations": return "eggNOG-mapper functional annotations."
    if n.endswith("_proteins.faa"): return "Prodigal predicted proteins."
    if n.endswith("_genes.gff"): return "Prodigal gene coordinates (GFF)."
    if n == "contig_coverage.tsv": return "Contig x sample coverage matrix."
    if n.endswith("_contig_report.txt"): return "Kraken2 contig taxonomy report."
    if n == "community_matrix.tsv": return "Full community table (taxon x sample)."
    if n.startswith("community_top") and n.endswith(".tsv"): return "Top-N taxa subset of the community table."
    if n == "SOURCE.txt": return "Abundance source used for the community tables."
    if n == "tool_versions.txt": return "Software versions used in this run."
    return "Delivered analysis file."

dictrows = []
for dp, _dirs, fs in os.walk(DELIVERY):
    for f in sorted(fs):
        if f in ("DATA_DICTIONARY.md", "report.html"):
            continue
        full = os.path.join(dp, f)
        rel = os.path.relpath(full, DELIVERY)
        dictrows.append([rel, describe(rel), os.path.getsize(full)])
dictrows.sort()

logo = ""
if LOGO_FILE and os.path.isfile(LOGO_FILE):
    try:
        logo = open(LOGO_FILE).read().strip()
    except Exception:
        logo = ""

data = {
    "run": {
        "project": PROJECT, "route": ROUTE, "basis": BASIS, "rawdata": RAWDATA,
        "samples": run_samples, "communitySource": COMMUNITY_SOURCE, "parallel": parallel,
        "generated": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "logo": logo,
    },
    "taxa": taxa, "mags": mags, "dict": dictrows,
}

CSS = r'''
  :root{--bg1:#eff6ff;--bg2:#dbe6f5;--panel:#fff;--ink:#33406a;--ink-soft:#4a5578;--muted:#7d8ca0;--line:#e4eaf3;--blue:#3b7de0;--blue-strong:#2f6fd0;--blue-soft:#cfe0f6;--navy:#1e2a66;--good:#2a9d8f;--warn:#d98a24;--bad:#e5556e;}
  *{box-sizing:border-box;} html,body{height:100%;}
  body{margin:0;color:var(--ink);background:linear-gradient(160deg,var(--bg1),var(--bg2));background-attachment:fixed;font-family:"Times New Roman",Times,serif;font-size:17px;line-height:1.55;}
  code,.mono,input,select,button,table{font-family:"Times New Roman",Times,serif;}
  .bg-lens{position:fixed;z-index:0;pointer-events:none;}
  #lensTR{top:-190px;right:-170px;width:640px;opacity:.09;transform:rotate(8deg);}
  #lensBL{bottom:-240px;left:-210px;width:760px;opacity:.06;transform:rotate(-14deg);}
  header,.meta,nav,main,footer{position:relative;z-index:1;}
  header{padding:22px 34px 8px;display:flex;align-items:center;gap:20px;flex-wrap:wrap;}
  .logo{height:88px;width:auto;display:block;}
  .headline{margin-left:auto;text-align:right;}
  .headline .t{font-size:22px;font-weight:700;}
  .headline .d{font-size:15px;color:var(--muted);}
  .meta{max-width:1180px;margin:0 auto;padding:6px 34px;display:flex;flex-wrap:wrap;gap:11px;}
  .chip{background:rgba(255,255,255,.8);border:1px solid var(--line);border-radius:10px;padding:8px 15px;font-size:15px;color:var(--ink-soft);}
  .chip b{color:var(--blue-strong);font-weight:700;}
  nav{max-width:1180px;margin:12px auto 0;padding:0 24px;display:flex;gap:4px;flex-wrap:wrap;border-bottom:1px solid var(--line);}
  nav button{background:none;border:none;color:var(--muted);padding:13px 18px;font-size:17px;cursor:pointer;border-bottom:3px solid transparent;font-weight:700;}
  nav button:hover{color:var(--ink);} nav button.active{color:var(--blue-strong);border-bottom-color:var(--blue-strong);}
  main{max-width:1180px;margin:0 auto;padding:24px 34px 8px;}
  section{display:none;} section.active{display:block;}
  h2{font-size:24px;margin:0 0 4px;} .hint{color:var(--muted);font-size:15.5px;margin:0 0 16px;}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:20px;margin-bottom:18px;box-shadow:0 8px 24px rgba(40,70,120,.06);}
  .controls{display:flex;gap:14px;align-items:center;flex-wrap:wrap;margin-bottom:14px;}
  label.ctl{font-size:15.5px;color:var(--muted);display:flex;gap:8px;align-items:center;}
  select,input[type="search"]{background:#fff;color:var(--ink);border:1px solid var(--line);border-radius:9px;padding:8px 12px;font-size:15px;}
  table{width:100%;border-collapse:collapse;font-size:15.5px;} th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);}
  th{color:var(--muted);font-weight:700;cursor:pointer;white-space:nowrap;} th:hover{color:var(--ink);}
  tbody tr:hover{background:rgba(59,125,224,.05);} td.num,th.num{text-align:right;font-variant-numeric:tabular-nums;}
  .bar-cell{position:relative;} .barfill{position:absolute;left:0;top:3px;bottom:3px;background:var(--blue-soft);border-right:2px solid var(--blue);border-radius:5px;} .barval{position:relative;padding-left:6px;}
  .tag{display:inline-block;padding:1px 9px;border-radius:6px;font-size:13.5px;} .tag.dir{background:rgba(59,125,224,.12);color:var(--blue-strong);}
  .legend{display:flex;flex-wrap:wrap;gap:8px 18px;margin-top:14px;font-size:14.5px;} .legend span{display:inline-flex;align-items:center;gap:6px;color:var(--muted);} .sw{width:13px;height:13px;border-radius:3px;display:inline-block;}
  .flex{display:flex;gap:16px;flex-wrap:wrap;} .stat{flex:1;min-width:150px;background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:18px;box-shadow:0 8px 24px rgba(40,70,120,.05);}
  .stat .k{font-size:14.5px;color:var(--muted);} .stat .v{font-size:32px;font-weight:800;color:var(--blue-strong);margin-top:2px;}
  .source-note{background:rgba(59,125,224,.07);border:1px solid rgba(59,125,224,.25);border-radius:10px;padding:11px 15px;font-size:15.5px;margin-bottom:14px;color:var(--ink-soft);} .source-note b{color:var(--blue-strong);}
  .heat-wrap{overflow-x:auto;} svg text{fill:var(--muted);font-size:13px;font-family:"Times New Roman",Times,serif;}
  .empty{color:var(--muted);font-size:15.5px;padding:8px 2px;}
  footer{color:var(--muted);font-size:14px;padding:24px 34px 32px;text-align:center;}
'''

LENS = ('<div class="bg-lens" id="lensTR" aria-hidden="true"><svg viewBox="0 0 200 200" width="100%" height="100%">'
        '<g fill="#3b7de0" stroke="#fff" stroke-width="0.8" stroke-opacity="0.5" stroke-linejoin="round">'
        '<polygon points="100,4 183.14,52 131.18,82 100,64" opacity="0.5"/>'
        '<polygon points="183.14,52 183.14,148 131.18,118 131.18,82" opacity="0.68"/>'
        '<polygon points="183.14,148 100,196 100,136 131.18,118" opacity="0.85"/>'
        '<polygon points="100,196 16.86,148 68.82,118 100,136" opacity="1"/>'
        '<polygon points="16.86,148 16.86,52 68.82,82 68.82,118" opacity="0.8"/>'
        '<polygon points="16.86,52 100,4 100,64 68.82,82" opacity="0.62"/></g></svg></div>'
        '<div class="bg-lens" id="lensBL" aria-hidden="true"><svg viewBox="0 0 200 200" width="100%" height="100%">'
        '<g fill="#2f6fd0" stroke="#fff" stroke-width="0.8" stroke-opacity="0.5" stroke-linejoin="round">'
        '<polygon points="100,4 183.14,52 131.18,82 100,64" opacity="0.5"/>'
        '<polygon points="183.14,52 183.14,148 131.18,118 131.18,82" opacity="0.68"/>'
        '<polygon points="183.14,148 100,196 100,136 131.18,118" opacity="0.85"/>'
        '<polygon points="100,196 16.86,148 68.82,118 100,136" opacity="1"/>'
        '<polygon points="16.86,148 16.86,52 68.82,82 68.82,118" opacity="0.8"/>'
        '<polygon points="16.86,52 100,4 100,64 68.82,82" opacity="0.62"/></g></svg></div>')

BODY = r'''
<header>
  <img class="logo" id="logo-img" alt="MetaGLens skills logo" />
  <div class="headline"><div class="t">Delivery Report</div><div class="d">Analysis-ready package</div></div>
</header>
<div class="meta">
  <div class="chip">Project: <b id="m-project"></b></div>
  <div class="chip">Route: <b id="m-route"></b></div>
  <div class="chip">Analysis basis: <b id="m-basis"></b></div>
  <div class="chip">Raw data folder: <b id="m-raw"></b></div>
  <div class="chip">Samples: <b id="m-nsamp"></b></div>
  <div class="chip">Generated: <b id="m-gen"></b></div>
</div>
<nav id="nav"></nav>
<main>
  <section id="tab-overview">
    <h2>Overview</h2>
    <p class="hint">Summary of the delivered analysis package.</p>
    <div class="source-note">Community abundance source: <b id="comm-source2"></b></div>
    <div class="flex" id="stats"></div>
  </section>
  <section id="tab-community">
    <h2>Community summary</h2>
    <p class="hint">Cross-sample taxonomic relative abundance.</p>
    <div class="source-note">Abundance source: <b id="comm-source"></b></div>
    <div class="controls">
      <label class="ctl">Show:<select id="topn"><option value="10">Top 10</option><option value="15" selected>Top 15</option><option value="999">All</option></select></label>
      <label class="ctl">View:<select id="commview"><option value="stack">Stacked bars</option><option value="table">Data table</option></select></label>
    </div>
    <div class="card" id="comm-chart-card"><div class="heat-wrap"><div id="comm-chart"></div></div><div class="legend" id="comm-legend"></div></div>
    <div class="card" id="comm-table-card" style="display:none"><div class="heat-wrap"><table id="comm-table"></table></div></div>
  </section>
  <section id="tab-mag">
    <h2>MAG abundance</h2>
    <p class="hint">Representative genome x sample relative abundance (%). Brighter = higher.</p>
    <div class="controls"><label class="ctl">Sort:<select id="magsort"><option value="abund">By total abundance</option><option value="name">By name</option></select></label></div>
    <div class="card heat-wrap"><div id="mag-heat"></div></div>
  </section>
  <section id="tab-quality">
    <h2>MAG quality</h2>
    <p class="hint">CheckM2 completeness / contamination. Click a header to sort.</p>
    <div class="card"><div class="heat-wrap"><table id="qual-table"></table></div></div>
  </section>
  <section id="tab-files">
    <h2>Files</h2>
    <p class="hint">Every file in this delivery folder and what it is.</p>
    <div class="controls"><input type="search" id="filesearch" placeholder="Search files or descriptions..." style="min-width:280px" /></div>
    <div class="card"><div class="heat-wrap"><table id="files-table"></table></div></div>
  </section>
</main>
<footer>MetaGLens delivery report. Values are computed from the tables in this delivery folder.</footer>
'''

JS = r'''
var MG=window.__MG__,RUN=MG.run,TAXA=MG.taxa,MAGS=MG.mags,FILES=MG.dict;
var PALETTE=["#3b7de0","#5f97dd","#7fb0e8","#9cc4ec","#2f6fd0","#6aa2e3","#4cc9f0","#8fbce8","#1e2a66","#4a89dc","#a7cbf0","#bcd8f2","#5878c8","#79a6e6","#2a9d8f","#c3d7f2"];
var $=function(s){return document.querySelector(s);};
function el(t,a,h){var e=document.createElement(t);a=a||{};for(var k in a)e.setAttribute(k,a[k]);if(h!=null)e.innerHTML=h;return e;}
if(RUN.logo){$("#logo-img").src=RUN.logo;}else{var w=$("#logo-img");var s=el("span",{},"MetaGLens");s.style.cssText="font-size:30px;font-weight:700;color:var(--ink)";w.parentNode.replaceChild(s,w);}
$("#m-project").textContent=RUN.project;$("#m-route").textContent=RUN.route;$("#m-basis").textContent=RUN.basis;
$("#m-raw").textContent=RUN.rawdata||"(not recorded)";$("#m-nsamp").textContent=RUN.samples.length;$("#m-gen").textContent=RUN.generated;
$("#comm-source").textContent=RUN.communitySource||"(none)";$("#comm-source2").textContent=RUN.communitySource||"(none)";
var TABS=[["overview","Overview"],["community","Community"],["mag","MAG abundance"],["quality","MAG quality"],["files","Files"]];
var nav=$("#nav");TABS.forEach(function(t,i){var b=el("button",{},t[1]);if(i===0)b.classList.add("active");b.onclick=function(){document.querySelectorAll("nav button").forEach(function(x){x.classList.remove("active");});document.querySelectorAll("section").forEach(function(x){x.classList.remove("active");});b.classList.add("active");$("#tab-"+t[0]).classList.add("active");};nav.appendChild(b);});
$("#tab-overview").classList.add("active");
var stats=[["Samples",RUN.samples.length],["Representative MAGs",MAGS.length],["Taxa",TAXA.length],["Parallel",RUN.parallel||"-"]];
stats.forEach(function(s){var d=el("div",{"class":"stat"});d.appendChild(el("div",{"class":"k"},s[0]));d.appendChild(el("div",{"class":"v"},s[1]));$("#stats").appendChild(d);});
function topTaxa(n){var rows=TAXA.map(function(t){return {name:t[0],vals:t[1],sum:t[1].reduce(function(a,b){return a+b;},0)};});rows.sort(function(a,b){return b.sum-a.sum;});if(n>=rows.length)return {rows:rows,other:null};var top=rows.slice(0,n),rest=rows.slice(n);var other=RUN.samples.map(function(_,i){return rest.reduce(function(a,r){return a+r.vals[i];},0);});return {rows:top,other:other};}
function renderCommunityChart(){if(!TAXA.length){$("#comm-chart").innerHTML='<div class="empty">No community table was produced for this run.</div>';$("#comm-legend").innerHTML="";return;}var n=parseInt($("#topn").value,10);var r=topTaxa(n);var series=r.other?r.rows.concat([{name:"Other",vals:r.other}]):r.rows.slice();var W=760,H=380,padL=46,padB=42,padT=10,padR=10;var gap=(W-padL-padR)/RUN.samples.length,bw=gap*0.58;var colTot=RUN.samples.map(function(_,i){return series.reduce(function(a,s){return a+s.vals[i];},0);});var svg='<svg width="'+W+'" height="'+H+'" viewBox="0 0 '+W+' '+H+'">';for(var g=0;g<=100;g+=25){var y=padT+(H-padT-padB)*(1-g/100);svg+='<line x1="'+padL+'" y1="'+y+'" x2="'+(W-padR)+'" y2="'+y+'" stroke="#e4eaf3"/><text x="6" y="'+(y+4)+'">'+g+'%</text>';}RUN.samples.forEach(function(s,i){var x=padL+gap*i+(gap-bw)/2,acc=0;series.forEach(function(ser,si){var val=colTot[i]?ser.vals[i]/colTot[i]*100:0,h=(H-padT-padB)*val/100,yy=padT+(H-padT-padB)-acc-h;var c=ser.name==="Other"?"#c3ccda":PALETTE[si%PALETTE.length];svg+='<rect x="'+x+'" y="'+yy+'" width="'+bw+'" height="'+h+'" fill="'+c+'"><title>'+ser.name+': '+val.toFixed(1)+'%</title></rect>';acc+=h;});svg+='<text x="'+(x+bw/2)+'" y="'+(H-padB+18)+'" text-anchor="middle" style="fill:#33406a">'+s+'</text>';});svg+='</svg>';$("#comm-chart").innerHTML=svg;var leg=$("#comm-legend");leg.innerHTML="";series.forEach(function(ser,si){var c=ser.name==="Other"?"#c3ccda":PALETTE[si%PALETTE.length];var sp=el("span");sp.innerHTML='<span class="sw" style="background:'+c+'"></span>'+ser.name;leg.appendChild(sp);});}
function renderCommunityTable(){if(!TAXA.length){$("#comm-table").innerHTML="";return;}var n=parseInt($("#topn").value,10);var r=topTaxa(n);var h="<thead><tr><th>Taxon</th>"+RUN.samples.map(function(s){return '<th class="num">'+s+' (%)</th>';}).join("")+"</tr></thead><tbody>";var maxv=Math.max.apply(null,r.rows.map(function(x){return Math.max.apply(null,x.vals);}));r.rows.forEach(function(row){h+="<tr><td>"+row.name+"</td>"+row.vals.map(function(v){var w=(maxv?v/maxv*100:0).toFixed(0);return '<td class="num bar-cell"><span class="barfill" style="width:'+w+'%"></span><span class="barval">'+v.toFixed(1)+'</span></td>';}).join("")+"</tr>";});h+="</tbody>";$("#comm-table").innerHTML=h;}
function renderCommunity(){var v=$("#commview").value;$("#comm-chart-card").style.display=v==="stack"?"block":"none";$("#comm-table-card").style.display=v==="table"?"block":"none";if(v==="stack")renderCommunityChart();else renderCommunityTable();}
$("#topn").onchange=renderCommunity;$("#commview").onchange=renderCommunity;renderCommunity();
function hcolor(v,max){var t=max?v/max:0;var c1=[233,240,249],c2=[47,111,208];var r=c1.map(function(a,i){return Math.round(a+(c2[i]-a)*t);});return "rgb("+r[0]+","+r[1]+","+r[2]+")";}
function renderMagHeat(){if(!MAGS.length){$("#mag-heat").innerHTML='<div class="empty">No MAGs were delivered for this run.</div>';return;}var mm=MAGS.map(function(m){return {name:m[0],comp:m[1],cont:m[2],vals:m[3],sum:m[3].reduce(function(a,b){return a+b;},0)};});if($("#magsort").value==="abund")mm.sort(function(a,b){return b.sum-a.sum;});else mm.sort(function(a,b){return a.name.localeCompare(b.name);});var maxv=Math.max.apply(null,mm.map(function(m){return Math.max.apply(null,m.vals);}));if(!isFinite(maxv)||maxv<=0)maxv=1;var cell=38,labelW=230,top=32,sw=cell;var W=labelW+RUN.samples.length*sw+10,H=top+mm.length*cell+10;var svg='<svg width="'+W+'" height="'+H+'" viewBox="0 0 '+W+' '+H+'">';RUN.samples.forEach(function(s,j){svg+='<text x="'+(labelW+j*sw+sw/2)+'" y="'+(top-10)+'" text-anchor="middle" style="fill:#33406a">'+s+'</text>';});mm.forEach(function(m,i){var y=top+i*cell;svg+='<text x="4" y="'+(y+cell/2+5)+'" style="fill:#33406a">'+m.name+'</text>';m.vals.forEach(function(v,j){var x=labelW+j*sw;svg+='<rect x="'+x+'" y="'+y+'" width="'+(sw-3)+'" height="'+(cell-3)+'" rx="5" fill="'+hcolor(v,maxv)+'" stroke="#e4eaf3"><title>'+m.name+' @ '+RUN.samples[j]+': '+v.toFixed(2)+'%</title></rect>';svg+='<text x="'+(x+(sw-3)/2)+'" y="'+(y+cell/2+5)+'" text-anchor="middle" style="fill:'+(v/maxv>0.5?"#fff":"#8695a8")+'">'+(v?v.toFixed(0):"")+'</text>';});});svg+='</svg>';$("#mag-heat").innerHTML=svg;}
$("#magsort").onchange=renderMagHeat;renderMagHeat();
var qs={col:4,dir:-1};
function renderQual(){if(!MAGS.length){$("#qual-table").innerHTML="<tbody><tr><td class='empty'>No MAGs were delivered.</td></tr></tbody>";return;}var cols=[["MAG",0,"t"],["Completeness %",1,"n"],["Contamination %",2,"n"],["Total abundance %",4,"n"]];var rows=MAGS.map(function(m){return [m[0],m[1],m[2],null,m[3].reduce(function(a,b){return a+b;},0)];});rows.sort(function(a,b){var c=qs.col,av=a[c],bv=b[c];if(av==null)av=-1;if(bv==null)bv=-1;return (typeof av==="number"?av-bv:(""+av).localeCompare(""+bv))*qs.dir;});var h="<thead><tr>"+cols.map(function(c){return '<th class="'+(c[2]==="n"?"num":"")+'" data-col="'+c[1]+'">'+c[0]+"</th>";}).join("")+"</tr></thead><tbody>";rows.forEach(function(r){var comp=r[1],cont=r[2];var cc=comp==null?"var(--muted)":(comp>=90?"var(--good)":comp>=70?"var(--warn)":"var(--bad)");var tc=cont==null?"var(--muted)":(cont<=5?"var(--good)":cont<=10?"var(--warn)":"var(--bad)");h+="<tr><td class='mono'>"+r[0]+"</td><td class='num' style='color:"+cc+";font-weight:700'>"+(comp==null?"-":comp.toFixed(1))+"</td><td class='num' style='color:"+tc+";font-weight:700'>"+(cont==null?"-":cont.toFixed(1))+"</td><td class='num'>"+r[4].toFixed(2)+"</td></tr>";});h+="</tbody>";var t=$("#qual-table");t.innerHTML=h;t.querySelectorAll("th").forEach(function(th){th.onclick=function(){var c=parseInt(th.dataset.col,10);qs.dir=qs.col===c?-qs.dir:(c>=1?-1:1);qs.col=c;renderQual();};});}
renderQual();
function fmtSize(b){if(b<1024)return b+" B";if(b<1048576)return (b/1024).toFixed(1)+" KB";return (b/1048576).toFixed(1)+" MB";}
function renderFiles(flt){flt=(flt||"").toLowerCase();var rows=FILES.filter(function(d){return d[0].toLowerCase().indexOf(flt)>=0||d[1].toLowerCase().indexOf(flt)>=0;});var h="<thead><tr><th>File</th><th>Description</th><th class='num'>Size</th></tr></thead><tbody>";if(!rows.length)h+="<tr><td colspan='3' class='empty'>No files.</td></tr>";rows.forEach(function(d){var dir=d[0].indexOf("/")>=0?d[0].split("/")[0]:"";h+="<tr><td class='mono'>"+(dir?'<span class="tag dir">'+dir+'</span> ':"")+d[0]+"</td><td>"+d[1]+"</td><td class='num'>"+fmtSize(d[2])+"</td></tr>";});h+="</tbody>";$("#files-table").innerHTML=h;}
$("#filesearch").oninput=function(e){renderFiles(e.target.value);};renderFiles();
'''

html_out = ('<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8"/>\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1.0"/>\n'
            '<title>' + _h.escape(PROJECT) + ' - MetaGLens Delivery Report</title>\n<style>' + CSS + '</style>\n</head>\n<body>\n'
            + LENS + '\n' + BODY + '\n<script>window.__MG__=' + json.dumps(data) + ';</script>\n<script>' + JS + '</script>\n</body>\n</html>\n')

with open(os.path.join(DELIVERY, "report.html"), "w", encoding="utf-8") as fh:
    fh.write(html_out)
print("report.html written (%d taxa, %d MAGs, %d files)." % (len(taxa), len(mags), len(dictrows)))
PY

# ===== Optional tarball =====
TARBALL=""
if [[ "${DO_TARBALL}" == "yes" ]]; then
    TARBALL="${RESULTS_DIR}/${PROJECT_NAME}_delivery.tar.gz"
    log "Creating tarball: ${TARBALL}"
    tar -czf "${TARBALL}" -C "${RESULTS_DIR}" "delivery"
    log "Tarball created: ${TARBALL}"
else
    log "DO_TARBALL=no — delivery left as a directory (no archive created)."
fi

# ===== Summary =====
DELIVERED_COUNT=$(find "${DELIVERY_DIR}" -type f ! -name 'DATA_DICTIONARY.md' ! -name 'report.html' | wc -l)
log_step "Delivery Summary"
log "Delivery directory : ${DELIVERY_DIR}/"
log "Files delivered    : ${DELIVERED_COUNT}"
log "Data dictionary    : ${DELIVERY_DIR}/DATA_DICTIONARY.md"
log "Interactive report : ${DELIVERY_DIR}/report.html"
log "Community source   : ${COMMUNITY_SOURCE}"

# ===== Update status and run log =====
update_step_status "${STEP_NAME}" "completed"
END_TIME=$(date '+%H:%M')

if [[ -f "${RUN_LOG}" ]]; then
    sed -i "s/| ${STEP_NAME} |[^|]*|[^|]*|[^|]*|/| ${STEP_NAME} | ✅ Completion | ${START_TIME} | ${END_TIME} |/" "${RUN_LOG}"
    cat >> "${RUN_LOG}" << EOFRUNLOGDEL

### 11 Delivery package
- **Delivery directory**: ${DELIVERY_DIR}/
- **Files delivered**: ${DELIVERED_COUNT}
- **Community abundance source**: ${COMMUNITY_SOURCE}
- **Data dictionary**: delivery/DATA_DICTIONARY.md
- **Interactive report**: delivery/report.html
- **Tarball**: ${TARBALL:-none}
- **Detailed log**: logs/11_delivery.log

EOFRUNLOGDEL
fi

log_step "Delivery completed"
echo ""
echo "Delivery package ready: ${DELIVERY_DIR}/"
echo "Open the interactive report: ${DELIVERY_DIR}/report.html"
echo "Read the data dictionary: ${DELIVERY_DIR}/DATA_DICTIONARY.md"
