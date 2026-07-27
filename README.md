![MetaGLens Skills banner](assets/metaglens-banner.png)

# MetaGLens Skills: AI-orchestrated metagenomics: reads → MAGs → annotation

![MetaGLens workflow demonstration](assets/metaglens-workflow-demo.gif)


MetaGLens Skills is a modular Codex skill bundle for designing reproducible
shotgun-metagenomics workflows from paired raw reads to metagenome-assembled
genomes (MAGs), taxonomy, functional annotation, and manuscript-ready Methods
text.

The bundle generates inspectable shell scripts instead of hiding analysis
steps behind an opaque wrapper. Each stage can be used independently or
orchestrated through the main `metaglens` skill.

## Workflow

At startup the orchestrator asks whether to run the whole pipeline or only
selected steps, then offers preset routes plus a custom option:

- `mag_per_sample` / `mag_co_binning` — MAG reconstruction with per-sample
  (逐个分箱) or co-assembly (联合分箱) binning.
- `contig_based` — contig-level analysis without binning.
- `mag_and_contig` — both branches.
- `custom` — a user-selected subset of steps.

1. **Project setup (`00_setup`)** — choose the route, inspect software
   environments, discover paired samples, plan parallelism (threads and jobs),
   initialize directories, and record provenance.
2. **Quality control (`01_qc`)** — filter and trim raw reads, with optional host
   and PhiX depletion.
3. **Assembly (`02_assembly`)** — assemble each sample independently or perform
   a co-assembly, then retain contigs above the selected length threshold.
4. **Read mapping (`03_mapping`)** — align quality-controlled reads to contigs
   and calculate coverage profiles.
5. **Genome binning (`04_binning`)** — reconstruct draft genomes with multiple
   binners, optionally refine with DAS Tool, then rename bins to
   `{label}_bin{N}.fa` and collect them in `04_binning/all_bins/`.
6. **MAG quality assessment (`05_checkm`)** — estimate completeness and
   contamination with CheckM2 and retain MAGs that meet the selected criteria.
7. **Dereplication (`06_derep`)** — cluster similar MAGs by average nucleotide
   identity and retain representative genomes.
8. **Taxonomic classification (`07_taxonomy`)** — classify MAGs with GTDB-Tk or
   profile reads with Kraken 2 and Bracken.
9. **Functional annotation (`08_annotation`)** — predict genes and assign
   functions for MAGs.
10. **Contig-based analysis (`09_contig`)** — for the contig route: Prodigal gene
    prediction, eggNOG-mapper functional annotation, optional contig taxonomy,
    and a contig coverage abundance table (no binning).
11. **Community summary (`10_community`)** — build a cross-sample community table
    and topN subsets; the abundance source is chosen automatically from the route
    and recorded for transparency.
12. **Delivery (`11_delivery`)** — assemble an analysis-ready package plus a
    `DATA_DICTIONARY.md` that explains every delivered file.

## Included skills

| Skill | Purpose | Primary tools |
|---|---|---|
| [`metaglens`](metaglens/SKILL.md) | End-to-end orchestration, environment inspection, sample discovery, state tracking, and Methods assembly | Conda, Bash, Python |
| [`metaglens-qc`](metaglens-qc/SKILL.md) | Read filtering and optional host/PhiX depletion | fastp, Bowtie 2 |
| [`metaglens-assembly`](metaglens-assembly/SKILL.md) | Per-sample assembly or co-assembly | MEGAHIT, metaSPAdes, SeqKit |
| [`metaglens-mapping`](metaglens-mapping/SKILL.md) | Read-to-contig alignment and coverage estimation | Bowtie 2, bwa-mem2, SAMtools, MetaBAT 2 utilities |
| [`metaglens-binning`](metaglens-binning/SKILL.md) | Independent binning and consensus refinement | MetaBAT 2, MaxBin 2, CONCOCT, DAS Tool |
| [`metaglens-checkm`](metaglens-checkm/SKILL.md) | MAG completeness/contamination assessment and filtering | CheckM2 |
| [`metaglens-derep`](metaglens-derep/SKILL.md) | ANI-based MAG dereplication | dRep, fastANI |
| [`metaglens-taxonomy`](metaglens-taxonomy/SKILL.md) | MAG classification or read-level taxonomic profiling | GTDB-Tk, Kraken 2, Bracken |
| [`metaglens-annotation`](metaglens-annotation/SKILL.md) | Gene prediction and functional annotation | Prokka, Prodigal, eggNOG-mapper |

Shared shell templates are stored in
[`shared/templates`](shared/templates), and tool citations are maintained in
[`shared/references.md`](shared/references.md).

## Design principles

- **Modular:** invoke one analytical stage or the complete workflow.
- **Route-configurable:** choose MAG (per-sample or co-binning), contig-based,
  both, or a custom subset; the step set and state file are built dynamically
  from the selected route.
- **Reproducible:** generate standalone shell scripts with explicit parameters.
- **Parallel-aware:** plan threads and concurrent jobs at setup; per-sample
  stages run concurrently locally or as scheduler array jobs.
- **Resumable:** track `pending`, `running`, `completed`, and `failed` states in
  `pipeline_status.json` for the steps in the chosen route.
- **Self-monitoring:** follow local processes or scheduler jobs to a terminal
  state, capture the failed command and log context, and apply bounded
  evidence-based script repairs.
- **Auditable:** record software versions, Conda package inventories, logs, and
  output paths.
- **Scheduler-aware:** adapt scripts for local execution, SLURM, or SGE.
- **Publication-oriented:** generate stage-specific Methods text from the
  software versions and parameters that were actually used.
- **Safety-conscious:** require confirmation before large database downloads,
  environment changes, or scheduler submission.

## Repository layout

```text
MetaGLens-skills/
├── metaglens/
│   └── SKILL.md
├── metaglens-qc/
│   └── SKILL.md
├── metaglens-assembly/
├── metaglens-mapping/
├── metaglens-binning/
├── metaglens-checkm/
├── metaglens-derep/
├── metaglens-taxonomy/
├── metaglens-annotation/
└── shared/
    ├── references.md
    └── templates/
        ├── 00_setup.sh
        ├── 01_quality_control.sh
        ├── ...
        ├── 08_annotation.sh
        └── _pipeline_utils.sh
```

Keep the skill directories and `shared/` as siblings. The skills use relative
links to the shared templates and references.

## Installation

Copy or clone the entire repository into a stable directory. Then place the
`metaglens*` skill directories and the sibling `shared/` directory under your
Codex skills root, preserving the layout:

```text
~/.codex/skills/
├── metaglens/
├── metaglens-qc/
├── metaglens-assembly/
├── metaglens-mapping/
├── metaglens-binning/
├── metaglens-checkm/
├── metaglens-derep/
├── metaglens-taxonomy/
├── metaglens-annotation/
└── shared/
```

Restart or reload Codex after installation so the skills are rediscovered.

## Example prompts

Invoke the complete workflow:

```text
Use $metaglens to design a resumable SLURM workflow from my paired shotgun
reads to dereplicated and annotated MAGs.
```

Invoke one stage:

```text
Use $metaglens-binning to generate a consensus binning script for my
co-assembly using MetaBAT2, MaxBin2, CONCOCT, and DAS Tool.
```

Resume a project:

```text
Use $metaglens to inspect pipeline_status.json and continue from the first
incomplete stage.
```

## Generated project outputs

A complete run is designed to create:

```text
metaglens_results/
├── 01_qc/
├── 02_assembly/
├── 03_mapping/
├── 04_binning/          # bins + all_bins/ ({label}_bin{N}.fa)
├── 05_checkm/
├── 06_derep/
├── 07_taxonomy/
├── 08_annotation/
├── 09_contig/           # contig-route genes, eggnog, taxonomy, abundance
├── 10_community/        # community_matrix.tsv, community_top*.tsv, SOURCE.txt
├── delivery/            # analysis-ready package + DATA_DICTIONARY.md + report.html
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

Directories for stages not used by the selected route stay empty.

## Interactive delivery report

![MetaGLens interactive report demonstration](assets/metaglens-report-demo.gif)

*The report is a single self-contained HTML file — open it in any browser.*

Every completed run also writes a **self-contained interactive report** at
`metaglens_results/delivery/report.html`. It is a single HTML file (logo and
styling embedded, no internet required) that visualizes the delivered tables:
the project, route and raw-data folder, a cross-sample community bar chart with
a Top-N switch, a MAG abundance heatmap, a sortable CheckM2 quality table, and a
searchable file list. You can open it locally or send the one file to a
collaborator.

Want to see what it looks like first? A ready-made sample is included:

- [`examples/report_sample.html`](examples/report_sample.html) — download it and
  open in any browser, or preview it rendered online via
  [htmlpreview](https://htmlpreview.github.io/?https://github.com/PengPPPP/MetaGLens-skills/blob/main/examples/report_sample.html).

## Important notes

- The templates are starting points. Review generated scripts before running
  them on production data or submitting them to a scheduler.
- Database releases and software interfaces change. Verify the installed tool
  versions and database documentation before a large run.
- The complete CheckM2, GTDB-Tk, Kraken 2, and eggNOG database set can require
  hundreds of gigabytes.
- MAG-retention thresholds must match the scientific question. The default
  50% completeness and 10% contamination thresholds are broad retention
  criteria, not a claim that every retained MAG is high quality.

## Recommended setup: run in tmux, manage from your phone

Metagenomic runs can take hours to days, so it helps to keep the session alive
and be able to check in from anywhere:

- **Run inside `tmux`** so the pipeline keeps going even if your SSH connection
  drops. Start a session with `tmux new -s metaglens`, launch the run, detach
  with `Ctrl-b d`, and reattach later with `tmux attach -t metaglens`. Because
  progress is tracked in `pipeline_status.json`, you can also stop and resume
  across sessions.
- **Drive it with QoderCLI / QoderCLICN.** Use the AI agent to
  invoke the `metaglens` skills, generate and inspect the scripts, monitor
  execution, and assemble the Methods text.
- **Manage on the go with the QoderCLI / QoderCLICN mobile app.** Pair the desktop
  agent with its mobile app to review progress, read `run_log.md`, open the
  `delivery/report.html`, and trigger the next step from your phone — handy for
  long, unattended runs.

Put together, you can kick off a long pipeline on a workstation or cluster, walk
away while `tmux` keeps everything running, and keep an eye on it from your
phone.

## References

See [`shared/references.md`](shared/references.md) for primary citations to the
tools used by the workflow.

## Contact

For questions, bug reports, or suggestions, contact
[chenghp0509@163.com](mailto:chenghp0509@163.com).

## AI usage statement

This project was developed with AI assistance (Qwen3.8-Max-Preview); all
development work was carried out in the Qoder editor.
