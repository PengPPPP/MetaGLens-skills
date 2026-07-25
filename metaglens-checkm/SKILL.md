---
name: metaglens-checkm
description: >-
  Generate reproducible CheckM2 workflows for assessing and filtering
  metagenome-assembled genomes by completeness and contamination. Use when a
  user asks about MAG quality, bin evaluation, CheckM2, completeness,
  contamination, MIMAG thresholds, or the quality-assessment stage of a
  metagenomics pipeline.
---

# MetaGLens CheckM2

Guide MAG quality assessment and filtering. Run this skill independently or as
stage 05 of the `metaglens` workflow.

## Collect inputs

Collect or inherit the project name, input-bin directory, bin extension, work
directory, execution environment, CheckM2 database path, completeness
threshold, contamination threshold, and thread count.

Defaults: minimum completeness 50%, maximum contamination 10%, and 16 threads.
Do not describe these thresholds as high-quality MIMAG criteria; they are a
broad downstream-retention threshold.

## Generate the script

Read
[`shared/templates/05_bin_evaluation.sh`](../shared/templates/05_bin_evaluation.sh),
replace all placeholders, and adapt scheduler directives.

Require the script to:

1. Validate stage `04_binning`, the database path, and a non-empty bin set.
2. Pass the correct extension to `checkm2 predict`.
3. Parse `quality_report.tsv` by header names when possible; otherwise validate
   that column 2 is completeness and column 3 is contamination.
4. Preserve the report header in `quality_report_filtered.tsv`.
5. Copy every retained bin while supporting `.fa`, `.fna`, and `.fasta`.
6. Report total, retained, and summary quality statistics.
7. Record completion or failure.

## Generate the Methods text

```text
MAG quality assessment

Genome completeness and contamination were estimated with CheckM2
(v{version}). Bins with at least {completeness}% completeness and no more than
{contamination}% contamination were retained for downstream analysis.
```

Use actual versions from `reports/tool_versions.txt` and cite CheckM2. Cite the
MIMAG paper only when the chosen categories or thresholds are explicitly tied
to that standard.

## Validate and deliver

- Run `bash -n`.
- Check the report schema and extension contract.
- Show the script and Methods paragraph before advancing.
- When execution is authorized, apply
  [`shared/execution-monitoring.md`](../shared/execution-monitoring.md).
