---
name: metaglens-assembly
description: >-
  Generate reproducible single-sample or co-assembly workflows for
  quality-filtered metagenomic reads with MEGAHIT or metaSPAdes. Use when a user
  asks about metagenome assembly, MEGAHIT, metaSPAdes, contigs, k-mer selection,
  co-assembly, or the assembly stage of a raw-reads-to-MAG pipeline.
---

# MetaGLens Assembly

Guide de novo metagenome assembly. Run this skill independently or as stage 02
of the `metaglens` workflow.

## Collect inputs

Reuse parent-workflow context when available. Otherwise collect the project
name, clean paired reads or sample manifest, work directory, execution
environment, assembler, assembly strategy, k-mer list, minimum contig length,
MEGAHIT preset, and thread count.

Use these defaults:

| Parameter | Default |
|---|---|
| Execution environment | `local` |
| Assembler | `megahit` |
| Strategy | per-sample |
| k-mers | `21,29,39,59,79,99,121,141` |
| Minimum contig length | `1000` bp |
| MEGAHIT preset | `meta-sensitive` |
| Threads | `16` |

Confirm sufficient memory and storage before selecting metaSPAdes or a large
co-assembly.

## Generate the script

Read [`shared/templates/02_assembly.sh`](../shared/templates/02_assembly.sh),
replace all placeholders, and adapt scheduler directives.

Require the script to:

1. Validate stage `01_qc`.
2. Resolve all input read pairs before launching an assembler.
3. Run MEGAHIT or metaSPAdes in per-sample or co-assembly mode.
4. Filter contigs with SeqKit.
5. Write canonical `final.contigs_filtered.fa` outputs.
6. Report contig counts, total length, longest contig, and N50.
7. Record completion or failure in the status and run-log files.

## Generate the Methods text

Use versions recorded in `reports/tool_versions.txt`.

```text
Metagenome assembly

Quality-filtered reads were assembled with {assembler} (v{version}) using
k-mer sizes of {kmer_list}. Contigs shorter than {min_length} bp were removed.
{Optional co-assembly sentence} {Optional MEGAHIT-preset sentence}
```

## Validate and deliver

- Run `bash -n` on the generated script.
- Confirm that each expected contig path matches the mapping-stage contract.
- Show the script and Methods paragraph before advancing.
- When execution is authorized, apply
  [`shared/execution-monitoring.md`](../shared/execution-monitoring.md).
