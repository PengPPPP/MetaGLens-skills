---
name: metaglens
description: >-
  Orchestrate a reproducible shotgun-metagenomics workflow from paired raw
  reads to quality-controlled reads, assemblies, coverage profiles, genome
  bins, quality-filtered and dereplicated MAGs, taxonomic classifications, and
  functional annotations. Use when a user asks for an end-to-end metagenomics
  pipeline, raw reads to MAGs, MetaGLens, reproducible shell scripts, resumable
  metagenomic analysis, monitored pipeline execution, bounded self-repair of a
  failed stage, or manuscript-ready Methods for a MAG workflow.
---

# MetaGLens

Orchestrate an end-to-end, resumable shotgun-metagenomics analysis. Generate
independent shell scripts and evidence-based Methods text; do not execute
expensive analyses or download databases without explicit user authorization.

## Delegate stages

Use the corresponding child skill for each analytical stage. Not every run
executes every stage: the stages that run are determined by the selected route
(see "Choose scope and route" below).

| Stage | Task | Child skill | Script |
|---|---|---|---|
| 00 | Project, environment, samples, databases, route, parallel plan | this skill | `00_setup.sh` |
| 01 | Read quality control | `metaglens-qc` | `01_quality_control.sh` |
| 02 | Assembly | `metaglens-assembly` | `02_assembly.sh` |
| 03 | Read mapping and depth | `metaglens-mapping` | `03_read_mapping.sh` |
| 04 | Genome binning (rename + collect) | `metaglens-binning` | `04_binning.sh` |
| 05 | MAG quality assessment | `metaglens-checkm` | `05_bin_evaluation.sh` |
| 06 | Dereplication | `metaglens-derep` | `06_dereplication.sh` |
| 07 | Taxonomy | `metaglens-taxonomy` | `07_taxonomy.sh` |
| 08 | Functional annotation (MAGs) | `metaglens-annotation` | `08_annotation.sh` |
| — | MAG abundance (reads → dereplicated MAGs) | this skill | `mag_abundance.sh` |
| 09 | Contig-based gene prediction + annotation + taxonomy + abundance | `metaglens-annotation` | `09_contig_analysis.sh` |
| 10 | Community summary tables (topN) | this skill | `10_community_summary.sh` |
| 11 | Delivery package + data dictionary | this skill | `11_delivery.sh` |

Pass the project configuration, sample manifest, selected environment, and
upstream output paths to each child skill. Do not ask for the same value twice
unless validation detects a conflict.

## Choose scope and route

Before collecting project settings, resolve what this run will do. Record the
outcome as `route_name`, `analysis_basis`, `binning_strategy`, and the ordered
`selected_steps` list, and pass them to `00_setup.sh`.

### Step A: scope

Ask whether the user wants to run:

- **the whole pipeline** — proceed to Step B to pick a route; or
- **only a specific step or steps** — set `route_name=custom`, ask which steps,
  and build `selected_steps` from that subset (always include `00_setup`).

### Step B: route (only when running the whole pipeline)

Offer the preset routes plus a custom option:

| Route | `analysis_basis` | `binning_strategy` | Steps (after `00_setup`) |
|---|---|---|---|
| `mag_per_sample` | mag | per_sample | 01_qc, 02_assembly, 03_mapping, 04_binning, 05_checkm, 06_derep, 07_taxonomy, mag_abundance, 08_annotation, 10_community, 11_delivery |
| `mag_co_binning` | mag | co_binning | 01_qc, 02_assembly, 03_mapping, 04_binning, 05_checkm, 06_derep, 07_taxonomy, mag_abundance, 08_annotation, 10_community, 11_delivery |
| `contig_based` | contig | none | 01_qc, 02_assembly, 03_mapping, 09_contig, 10_community, 11_delivery |
| `mag_and_contig` | both | per_sample or co_binning | 01_qc, 02_assembly, 03_mapping, 04_binning, 05_checkm, 06_derep, 07_taxonomy, mag_abundance, 08_annotation, 09_contig, 10_community, 11_delivery |
| `custom` | as needed | as needed | user-selected subset |

`mag_per_sample` and `mag_co_binning` differ only by `binning_strategy`, which
maps to the assembly strategy (`per_sample` → per-sample assembly; `co_binning`
→ co-assembly with multi-sample depth). For `mag_and_contig`, still ask the
binning strategy for the MAG branch.

### Step C: analysis basis and binning strategy

When the route does not already fix these, ask explicitly:

1. `analysis_basis`: `mag`, `contig`, or `both`.
2. If `analysis_basis` includes `mag`: `binning_strategy` = `per_sample`
   (逐个分箱) or `co_binning` (联合分箱).

For `custom` routes, derive `analysis_basis`/`binning_strategy` from the chosen
steps and compose the run from the existing stage scripts, honoring each stage's
prerequisites.


## Phase 0: initialize the project

### Step 0-1: collect project settings

Collect:

| Parameter | Default |
|---|---|
| Project name | required |
| Raw-data directory | required |
| Work directory | `./{project_name}` |
| Database directory | `{work_directory}/databases` |
| Execution environment | `local` |
| Total available threads | `16` |
| Parallel jobs x threads/job | derived (see Phase 0 parallel plan) |
| Memory | environment-dependent |
| Download databases automatically | `no` |

Accept `local`, `SLURM`, or `SGE`. Explain that the complete database set can
exceed 200 GB and take hours to prepare. Require explicit approval before
setting `DOWNLOAD_DBS=yes`.

### Step 0-1b: plan parallelism

Ask for the **total available threads** (`TOTAL_THREADS`). Combine this with the
sample count to propose a parallel plan for per-sample stages:

- `parallel_jobs` = number of samples processed concurrently.
- `threads_per_job` = `TOTAL_THREADS / parallel_jobs` (at least 1).
- Choose `parallel_jobs` so that `parallel_jobs * threads_per_job <= TOTAL_THREADS`.
  A common default is `parallel_jobs = min(sample_count, TOTAL_THREADS)` with the
  remaining threads distributed per job; present options and let the user pick.

For `local`, per-sample stages run concurrently via the shared `run_parallel`
helper. For `SLURM`/`SGE`, per-sample stages emit array jobs (one task per
sample) and `threads_per_job` becomes the per-task CPU request. Cross-sample
stages (co-assembly, CheckM2, dRep, GTDB-Tk) run as a single job using all
threads. Record `exec_env`, `total_threads`, `parallel_jobs`, and
`threads_per_job` in `pipeline_status.json.parallel`.

### Step 0-2: inspect software environments

Before creating an environment:

1. Run `conda env list`.
2. Check candidate environments for fastp, MEGAHIT, SPAdes, Bowtie2,
   samtools, SeqKit, MetaBAT2, MaxBin2, CONCOCT, DAS Tool, CheckM2, dRep,
   GTDB-Tk, Kraken2, Bracken, Prokka, Prodigal, and eggNOG-mapper.
3. Record installed versions without changing the environments.
4. Query current package metadata only when network access is authorized.
5. Present a concise installed/missing/outdated table.

Offer these choices:

- `create`: create three isolated environments.
- `reuse`: install only missing tools in an existing environment.
- `reuse_and_update`: update only tools explicitly selected by the user, then
  install missing tools.
- `none`: rely on tools already available on `PATH`.

Do not run a blanket `conda update --all`; it can destabilize unrelated tools.
For `create`, use:

- `{project}_qc`: stages 01-03.
- `{project}_binning`: stage 04.
- `{project}_mag`: stages 05-08.

Record the decision in `pipeline_status.json`.

### Step 0-3: discover samples

Scan the raw-data directory for `.fastq`, `.fq`, and gzip-compressed variants.
Detect common paired-end conventions, including `_R1/_R2`, `_1/_2`,
`_R1_001/_R2_001`, and `.1/.2`.

Create a tab-separated `samples.tsv` with these columns:

```text
sample_id	r1	r2
sample01	/absolute/path/sample01_R1.fastq.gz	/absolute/path/sample01_R2.fastq.gz
```

Validate that:

- sample identifiers are unique;
- every file exists and is readable;
- each sample has exactly one R1 and one R2 file;
- no file is assigned to more than one sample.

Show the discovered manifest and ask the user to confirm exclusions or pairing
corrections. Use the manifest in downstream scripts instead of reconstructing
file names from sample identifiers.

### Step 0-4: generate setup resources

Read [`shared/templates/00_setup.sh`](../shared/templates/00_setup.sh), replace
all placeholders, and adapt or remove scheduler directives.

Create:

```text
metaglens_results/
├── 01_qc/
├── 02_assembly/
├── 03_mapping/
├── 04_binning/
├── 05_checkm/
├── 06_derep/
├── 07_taxonomy/
├── 08_annotation/
├── 09_contig/
├── 10_community/
├── delivery/
├── reports/
│   ├── logs/
│   ├── run_log.md
│   ├── tool_versions.txt
│   ├── conda_env_packages.tsv
│   ├── methods.md
│   ├── repair_log.jsonl
│   ├── repairs/
│   └── references.md
├── samples.tsv
├── pipeline_status.json
└── pipeline_utils.sh
```

Stage directories not used by the selected route stay empty. Create the full
set for a consistent layout.

Copy `shared/templates/_pipeline_utils.sh` to the results root as
`pipeline_utils.sh`. Every stage script must source this file and fail clearly
if it is missing.

Also copy `shared/templates/report_logo.b64` to the results root as
`report_logo.b64`. Stage 11 embeds it into `delivery/report.html` so the report
stays a self-contained single file; if it is missing the report still renders
with a text title.

## State and resume contract

Use `pipeline_status.json` as the authoritative state file. Its `steps` object
is **built dynamically from `selected_steps`** for the chosen route, not fixed
at eight stages:

```json
{
  "project_name": "{project_name}",
  "work_dir": "{work_dir}",
  "results_dir": "{work_dir}/metaglens_results",
  "sample_manifest": "{work_dir}/metaglens_results/samples.tsv",
  "route_name": "mag_per_sample|mag_co_binning|contig_based|mag_and_contig|custom",
  "analysis_basis": "mag|contig|both",
  "binning_strategy": "per_sample|co_binning|none",
  "selected_steps": ["00_setup", "01_qc", "02_assembly", "..."],
  "parallel": {
    "exec_env": "local|slurm|sge",
    "total_threads": 16,
    "parallel_jobs": 4,
    "threads_per_job": 4
  },
  "conda_mode": "create|reuse|reuse_and_update|none",
  "conda_envs": {
    "qc": "{environment}",
    "binning": "{environment}",
    "mag": "{environment}"
  },
  "monitoring": {
    "enabled": true,
    "max_auto_repair_attempts": 2
  },
  "steps": {
    "00_setup": {"status": "completed", "attempts": 1},
    "01_qc": {"status": "pending", "attempts": 0}
  }
}
```

Only steps listed in `selected_steps` appear in `steps`. Use only `pending`,
`running`, `completed`, and `failed`.

Require every stage script to:

1. Validate the status file and its prerequisite stage. Prerequisite checks are
   route-aware: a prerequisite that is not in `selected_steps` is skipped
   (its inputs are assumed to be user-provided).
2. Exit successfully when the current stage is already completed.
3. Set the current stage to `running` immediately before execution.
4. Install an error trap that sets the stage to `failed`.
5. Record the attempt count, exit code, failed command, line number, and log
   path when available.
6. Set the stage to `completed` only after all expected outputs pass validation.
7. Append an English summary to `reports/run_log.md`.

At the start of a later conversation, inspect this file and resume from the
first non-completed step in `selected_steps`.

## Stage-by-stage workflow

For each stage:

1. Invoke the matching child skill.
2. Pass validated upstream paths and the sample manifest.
3. Collect only stage-specific choices.
4. Generate the script from its template.
5. Replace every placeholder; fail validation if any `{{...}}` remains.
6. Run `bash -n`.
7. Verify input/output path contracts with the next stage.
8. Generate a provisional Methods paragraph.
9. Show the script and paragraph for user confirmation.
10. Advance only after confirmation.

Scripts must remain runnable after the AI session ends.

## Parallel execution

`shared/templates/_pipeline_utils.sh` provides `load_parallel_plan`,
`run_parallel`, `resolve_task_samples`, and `current_task_index`. Per-sample
stages (01 QC, per-sample 02 assembly, 03 mapping, per-sample 04 binning, 09
contig gene prediction/taxonomy) process samples concurrently up to
`parallel_jobs`, each using `threads_per_job`. Cross-sample stages (co-assembly,
CheckM2, dRep, GTDB-Tk, combined eggNOG-mapper) run as a single job with all
threads. For `SLURM`/`SGE`, submit per-sample stages as array jobs
(`--array=1-N` / `-t 1-N`); `resolve_task_samples` restricts each task to its
sample.

## Community summary and delivery

- **Stage 10 (`10_community_summary.sh`)** builds a cross-sample community table
  and topN subsets. The abundance source is chosen automatically from available
  outputs, in priority order: Kraken2/Bracken relative abundance (read/contig
  routes); MAG relative abundance from `mag_abundance.sh` aggregated by GTDB-Tk
  taxonomy (MAG route with the abundance step); GTDB-Tk representative-genome
  counts (MAG route fallback); or Kraken2 report composition. The chosen source
  is written to `10_community/SOURCE.txt`. Collect the topN cut-offs
  (default `10 15`) and the Bracken level (default `S`).
- **Stage 11 (`11_delivery.sh`)** assembles analysis-ready outputs into
  `delivery/` (genomes, tables, annotations, taxonomy, contig outputs, community
  tables), generates `delivery/DATA_DICTIONARY.md` describing every file, and
  builds `delivery/report.html`: a self-contained interactive report (light
  poster theme, embedded logo, Times New Roman) populated from the real
  delivered tables and headed with the project, route, and raw-data folder.
  Tarball creation is optional (`DO_TARBALL=yes`) and requires user
  confirmation. Pass `RAW_DATA_DIR` so the report shows the raw-reads folder.

## Execution monitoring and self-repair

When the user authorizes execution or asks the AI to monitor a run, read and
apply
[`shared/execution-monitoring.md`](../shared/execution-monitoring.md).

Do not return immediately after launching a local process or scheduler job.
Monitor it to a terminal state, validate the outputs, and report the evidence.
On failure, diagnose the recorded error and patch the generated stage script
only when the evidence supports a script defect. Validate the patch and re-run
only the failed stage. Stop after two unsuccessful automatic repair attempts or
when the repair requires new user authorization.

## Version and provenance policy

- Do not hard-code package versions in installation commands unless the user
  requests a locked environment.
- Record actual executable versions in `reports/tool_versions.txt`.
- Export complete package inventories to
  `reports/conda_env_packages.tsv`.
- Tag versions as `[new]`, `[reused]`, or `[updated]` accurately.
- Treat versions in [`shared/references.md`](../shared/references.md) as
  baselines, not claims about the active environment.
- Use actual versions in final Methods text.
- Record database releases separately from software versions.

## Logging and Methods

Keep `reports/run_log.md` in English. Include project configuration, sample
manifest, environment mapping, stage progress, stage summaries, final metrics,
and output locations.

Generate one concise, past-tense Methods subsection per executed stage. Include
the tool version and scientifically relevant parameters. Do not mention tools
or optional branches that did not run. Assemble the final
`reports/methods.md` and `reports/references.md` from the executed stages only.

Use [`shared/references.md`](../shared/references.md) for citation details.

## Validation and safety

Before delivering generated resources:

- run `bash -n` on every shell script;
- check for unresolved placeholders;
- check that all referenced relative resources exist;
- apply the monitoring and bounded self-repair contract when execution is
  authorized;
- check for non-English text when English-only output is requested;
- validate JSON and TSV contracts;
- require explicit approval before large downloads, environment changes, or
  scheduler submission, scientific-parameter changes, or destructive cleanup;
- never report a stage as completed without validating its expected outputs.
