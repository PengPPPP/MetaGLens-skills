---
name: metaglens-taxonomy
description: >-
  Generate reproducible taxonomic-classification workflows for MAGs with
  GTDB-Tk or for metagenomic reads with Kraken2 and optional Bracken. Use when
  a user asks about taxonomy, species profiling, GTDB-Tk, Kraken2, Bracken,
  MAG classification, read-level taxonomic profiles, or the taxonomy stage of
  a metagenomics pipeline.
---

# MetaGLens Taxonomy

Guide either MAG classification with GTDB-Tk or read-level profiling with
Kraken2 and Bracken. Run this skill independently or as stage 07 of the
`metaglens` workflow.

## Collect inputs

Collect or inherit the project name, workflow branch (`gtdbtk` or `kraken2`),
input path or sample manifest, work directory, execution environment, database
path and release, Kraken2 confidence, Bracken use and read length, and thread
count.

Defaults: GTDB-Tk, Kraken2 confidence 0, Bracken read length 150, and 16
threads.

## Generate the script

Read [`shared/templates/07_taxonomy.sh`](../shared/templates/07_taxonomy.sh),
replace all placeholders, and adapt scheduler directives.

Require the script to:

1. Validate stage `06_derep` for the full workflow.
2. Validate the selected database and input paths.
3. For GTDB-Tk, set `GTDBTK_DATA_PATH`, detect the genome extension, and run
   `classify_wf`.
4. Summarize both bacterial and archaeal GTDB-Tk output files when present.
5. For Kraken2, resolve every clean read pair, generate per-sample output and
   reports, and optionally run Bracken.
6. Guard all percentage calculations against zero denominators.
7. Record completion or failure.

## Generate the Methods text

For GTDB-Tk:

```text
Taxonomic classification

MAGs were classified with GTDB-Tk (v{version}) using `classify_wf` against
GTDB release {release}.
```

For Kraken2:

```text
Taxonomic profiling

Quality-filtered reads were classified with Kraken2 (v{version}) against the
{database} database. {Optional confidence sentence} {Optional Bracken sentence}
```

Use actual software and database versions.

## Validate and deliver

- Run `bash -n`.
- Confirm which branch the user selected.
- Show the script and Methods paragraph before advancing.
- When execution is authorized, apply
  [`shared/execution-monitoring.md`](../shared/execution-monitoring.md).
