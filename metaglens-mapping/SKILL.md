---
name: metaglens-mapping
description: >-
  Generate reproducible read-to-contig alignment, sorted BAM, mapping summary,
  and contig-depth workflows with Bowtie2 or bwa-mem2 and samtools. Use when a
  user asks about metagenomic read mapping, Bowtie2, bwa-mem2, BAM files,
  contig coverage, abundance estimation, or the mapping stage before binning.
---

# MetaGLens Mapping

Guide read mapping and contig-depth estimation. Run this skill independently or
as stage 03 of the `metaglens` workflow.

## Collect inputs

Collect or inherit the project name, clean-read manifest, contig paths,
assembly strategy, work directory, execution environment, aligner, alignment
mode, depth-calculation choice, and thread count.

Defaults: `local`, Bowtie2, `very-sensitive`, depth calculation enabled, and
16 threads.

## Generate the script

Read
[`shared/templates/03_read_mapping.sh`](../shared/templates/03_read_mapping.sh),
replace all placeholders, and adapt scheduler directives.

Require the script to:

1. Validate stage `02_assembly`.
2. Resolve `final.contigs_filtered.fa`, `final.contigs.fa`, or `contigs.fasta`
   explicitly and fail if none exists.
3. Build the selected aligner's index.
4. align reads and stream output to `samtools sort`.
5. Write `03_mapping/{sample}/{sample}.sorted.bam` and its index.
6. Record alignment statistics.
7. Calculate per-sample depth when requested.
8. For a co-assembly, calculate a shared depth table from all sample BAMs for
   downstream binning.
9. Record completion or failure.

## Generate the Methods text

```text
Read mapping and abundance estimation

Quality-filtered reads were aligned to assembled contigs with {aligner}
(v{version}) in {mode} mode. Sorted BAM files were produced with samtools
(v{version}), and contig coverage was calculated with
jgi_summarize_bam_contig_depths from MetaBAT2 (v{version}).
```

Use actual versions from `reports/tool_versions.txt`.

## Validate and deliver

- Run `bash -n` on the script.
- Confirm that BAM and depth paths match the binning template.
- Show the script and Methods paragraph before advancing.
- When execution is authorized, apply
  [`shared/execution-monitoring.md`](../shared/execution-monitoring.md).
