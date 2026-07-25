---
name: metaglens-derep
description: >-
  Generate reproducible dRep workflows that dereplicate quality-filtered
  metagenome-assembled genomes by average nucleotide identity. Use when a user
  asks about MAG dereplication, dRep, ANI thresholds, representative genomes,
  non-redundant genome sets, or the dereplication stage of a metagenomics
  pipeline.
---

# MetaGLens Dereplication

Guide MAG dereplication with dRep. Run this skill independently or as stage 06
of the `metaglens` workflow.

## Collect inputs

Collect or inherit the project name, input-bin directory, CheckM2 filtered
report, work directory, execution environment, secondary ANI threshold, and
thread count.

Defaults: 95% secondary ANI and 16 threads. Accept `95` or `0.95`, then
normalize to the 0-1 value expected by dRep.

## Generate the script

Read
[`shared/templates/06_dereplication.sh`](../shared/templates/06_dereplication.sh),
replace all placeholders, and adapt scheduler directives.

Require the script to:

1. Validate stage `05_checkm` and a non-empty set of `.fa`, `.fna`, or
   `.fasta` genomes.
2. Build a `genomeInfo.csv` file from the CheckM2 filtered report.
3. Use `-sa` for the requested secondary-clustering ANI threshold.
4. Verify dRep option compatibility before selecting `fastANI`.
5. Locate dRep's actual representative-genome directory and fail if empty.
6. Report input, representative, and removed genome counts.
7. Record completion or failure.

Avoid a second CheckM v1 run when validated CheckM2 quality values are
available.

## Generate the Methods text

```text
MAG dereplication

Quality-filtered MAGs were dereplicated with dRep (v{version}) at
{ani}% average nucleotide identity, and one representative genome was retained
per secondary cluster.
```

## Validate and deliver

- Run `bash -n`.
- Confirm dRep options against the installed version.
- Show the script and Methods paragraph before advancing.
- When execution is authorized, apply
  [`shared/execution-monitoring.md`](../shared/execution-monitoring.md).
