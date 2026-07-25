---
name: metaglens-annotation
description: >-
  Generate reproducible gene-prediction and functional-annotation workflows
  for metagenome-assembled genomes with Prokka, Prodigal, and eggNOG-mapper.
  Use when a user asks about MAG annotation, gene prediction, Prokka, Prodigal,
  eggNOG-mapper, COG, KEGG, GO, or the functional-annotation stage of a
  metagenomics pipeline.
---

# MetaGLens Annotation

Guide gene prediction and functional annotation. Run this skill independently
or as stage 08 of the `metaglens` workflow.

## Collect inputs

Collect or inherit the project name, MAG directory, work directory, execution
environment, selected annotation tools, eggNOG data directory, genetic code,
organism domain, and thread count.

Defaults: Prokka plus eggNOG-mapper, bacterial domain, genetic code 11, and 16
threads. Do not force `--kingdom Bacteria` when archaeal MAGs are present;
split inputs or collect an explicit domain choice.

## Generate the script

Read [`shared/templates/08_annotation.sh`](../shared/templates/08_annotation.sh),
replace all placeholders, and adapt scheduler directives.

Require the script to:

1. Validate stage `07_taxonomy` for the full workflow and require a non-empty
   MAG set.
2. Run Prokka per MAG when enabled.
3. Otherwise run Prodigal in metagenomic mode before eggNOG-mapper.
4. Prefix sequence identifiers with the MAG identifier before concatenating
   proteins, preventing collisions across genomes.
5. Validate the eggNOG database before running `emapper.py`.
6. Report predicted and annotated sequence counts with a guarded percentage.
7. Record completion or failure and append the final English run-log summary.

## Generate the Methods text

```text
Functional annotation

{Optional Prokka sentence} {Optional Prodigal sentence} Protein functions were
assigned with eggNOG-mapper (v{version}) in DIAMOND mode against eggNOG
{database_version}.
```

Do not claim KEGG, CAZy, COG, or GO coverage unless the generated outputs and
selected eggNOG fields support that claim.

## Validate and deliver

- Run `bash -n`.
- Verify unique protein identifiers and non-empty protein input.
- Show the script and Methods paragraph.
- Assemble the final Methods and references only from stages that actually ran.
- When execution is authorized, apply
  [`shared/execution-monitoring.md`](../shared/execution-monitoring.md).
