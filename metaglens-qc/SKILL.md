---
name: metaglens-qc
description: >-
  Generate a reproducible metagenomic read quality-control workflow with fastp,
  optional host-read removal, and optional PhiX removal. Use when a user asks
  about metagenomic QC, read filtering, adapter trimming, fastp, host depletion,
  PhiX removal, or the quality-control stage of a raw-reads-to-MAG pipeline.
---

# MetaGLens QC

Guide quality control for paired-end shotgun metagenomic reads. Run this skill
independently or as stage 01 of the `metaglens` workflow.

## Collect inputs

Reuse project context supplied by the parent workflow. Otherwise collect:

| Parameter | Default |
|---|---|
| Project name | required |
| Paired-read paths or sample manifest | required |
| Work directory | `./{project_name}` |
| Execution environment | `local` |
| Minimum Phred score | `15` |
| Minimum retained read length | `75` bp |
| Host removal and reference/index | disabled |
| PhiX removal and reference/index | disabled |
| Threads | `16` |

Accept `local`, `SLURM`, or `SGE` as execution environments. Confirm that every
sample has an R1/R2 pair before generating a script.

## Generate the script

Read
[`shared/templates/01_quality_control.sh`](../shared/templates/01_quality_control.sh)
and replace every `{{PLACEHOLDER}}`. Adapt or remove scheduler directives for
the selected execution environment.

Require the generated script to:

1. Validate `pipeline_status.json` and stage `00_setup`.
2. Run fastp for each sample.
3. Build Bowtie2 indexes when host or PhiX FASTA files are supplied.
4. Retain unmapped paired reads when depletion is enabled.
5. Write clean reads and fastp JSON/HTML reports to `01_qc/`.
6. Record completion or failure and append an English summary to `run_log.md`.

Copy `shared/templates/_pipeline_utils.sh` to the results root as
`pipeline_utils.sh`. Do not generate a stage script without this dependency.

## Generate the Methods text

Use the actual versions in `reports/tool_versions.txt`. If setup has not run,
use the baseline in [`shared/references.md`](../shared/references.md), label it
as provisional, and instruct the user to update the text after execution.

```text
Quality control and preprocessing

Raw paired-end reads were filtered with fastp (v{version}) using a minimum
Phred score of Q{quality} and a minimum retained length of {length} bp.
{Optional host-removal sentence}
{Optional PhiX-removal sentence}
```

## Validate and deliver

- Run `bash -n` on the generated script.
- Show the complete script and Methods paragraph.
- Explain each non-default parameter.
- Wait for confirmation before advancing to assembly.
- When execution is authorized, apply
  [`shared/execution-monitoring.md`](../shared/execution-monitoring.md).
