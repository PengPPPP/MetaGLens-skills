---
name: metaglens-binning
description: >-
  Generate reproducible metagenomic binning workflows with MetaBAT2, MaxBin2,
  CONCOCT, and optional DAS Tool refinement. Use when a user asks about genome
  binning, MAG reconstruction, MetaBAT2, MaxBin2, CONCOCT, DAS Tool,
  contig-to-bin tables, or the binning stage of a metagenomics pipeline.
---

# MetaGLens Binning

Guide genome binning from assembled contigs and coverage data. Run this skill
independently or as stage 04 of the `metaglens` workflow.

## Collect inputs

Collect or inherit the project name, contig path, BAM/depth inputs, work
directory, execution environment, selected binners, DAS Tool choice, minimum
contig length, binning strategy, group label, sample list, and the parallel plan
(total threads, parallel jobs, threads per job).

Defaults: enable MetaBAT2, MaxBin2, CONCOCT, and DAS Tool; use a minimum contig
length of 1,500 bp. `GROUP_LABEL` (used to prefix renamed bins in co-binning)
defaults to the project name.

## Generate the script

Read [`shared/templates/04_binning.sh`](../shared/templates/04_binning.sh),
replace all placeholders, and adapt scheduler directives.

Require the script to:

1. Validate stage `03_mapping` and all required contig/BAM files.
2. Use the shared multi-sample depth table for co-assemblies.
3. Convert MetaBAT2 depth output to the two-column abundance input expected by
   MaxBin2.
4. Build a non-empty BAM list before running CONCOCT.
5. Convert each FASTA bin directory to a contig-to-bin table with
   `Fasta_to_Contig2Bin.sh` before running DAS Tool.
6. Pass `--write_bins` to DAS Tool and resolve its actual output directory.
7. Bin each unit concurrently (per-sample binning) via the shared `run_parallel`
   helper, or as a single all-threads job for co-binning. Support scheduler
   array jobs through `resolve_task_samples`.
8. After refinement, select the final bin set (DAS Tool consensus, or the first
   enabled binner when DAS Tool is off), **rename** each bin to
   `{label}_bin{N}.fa` (label = sample id for per-sample, `GROUP_LABEL` for
   co-binning), and **collect** all renamed bins into `04_binning/all_bins/`.
9. Record completion or failure.

`04_binning/all_bins/` is the canonical input for stage 05 (`BINS_DIR`). The
sample-prefixed names keep every downstream MAG traceable to its source.

Do not pass directories directly to DAS Tool's `-i` option; it expects
comma-separated contig-to-bin mapping files.

## Generate the Methods text

```text
Genome binning

Contigs of at least {min_contig} bp were binned independently with
{tools_list}. {Optional DAS Tool refinement sentence}
```

Use actual versions from `reports/tool_versions.txt`.

## Validate and deliver

- Run `bash -n`.
- Verify that at least one binner is enabled.
- Verify the mapping-to-binning path contract.
- Show the script and Methods paragraph before advancing.
- When execution is authorized, apply
  [`shared/execution-monitoring.md`](../shared/execution-monitoring.md).
