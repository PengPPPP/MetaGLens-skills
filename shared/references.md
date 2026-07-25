# MetaGLens tool references

> Version numbers are baseline examples only. Use the versions recorded in
> `reports/tool_versions.txt` for executed workflows. Record complete Conda
> package inventories in `reports/conda_env_packages.tsv`.

## Quality control

- **fastp** — Chen, S., Zhou, Y., Chen, Y. & Gu, J. fastp: an ultra-fast
  all-in-one FASTQ preprocessor. *Bioinformatics* **34**, i884–i890 (2018).
  https://doi.org/10.1093/bioinformatics/bty560

- **Bowtie 2** — Langmead, B. & Salzberg, S. L. Fast gapped-read alignment
  with Bowtie 2. *Nature Methods* **9**, 357–359 (2012).
  https://doi.org/10.1038/nmeth.1923

## Assembly

- **MEGAHIT** — Li, D., Liu, C.-M., Luo, R., Sadakane, K. & Lam, T.-W.
  MEGAHIT: an ultra-fast single-node solution for large and complex
  metagenomics assembly via succinct de Bruijn graph. *Bioinformatics* **31**,
  1674–1676 (2015). https://doi.org/10.1093/bioinformatics/btv033

- **metaSPAdes** — Nurk, S. *et al.* metaSPAdes: a new versatile metagenomic
  assembler. *Genome Research* **27**, 824–834 (2017).
  https://doi.org/10.1101/gr.213959.116

## Read mapping

- **Bowtie 2** — Langmead, B. & Salzberg, S. L. Fast gapped-read alignment
  with Bowtie 2. *Nature Methods* **9**, 357–359 (2012).
  https://doi.org/10.1038/nmeth.1923

- **SAMtools** — Danecek, P. *et al.* Twelve years of SAMtools and BCFtools.
  *GigaScience* **10**, giab008 (2021).
  https://doi.org/10.1093/gigascience/giab008

- **bwa-mem2** — Vasimuddin, M., Misra, S., Li, H. & Aluru, S. Efficient
  architecture-aware acceleration of BWA-MEM for multicore systems. *2019 IEEE
  International Parallel and Distributed Processing Symposium*, 314–324
  (2019). https://doi.org/10.1109/IPDPS.2019.00041

## Genome binning

- **MetaBAT 2** — Kang, D. D. *et al.* MetaBAT 2: an adaptive binning
  algorithm for robust and efficient genome reconstruction from metagenome
  assemblies. *PeerJ* **7**, e7359 (2019).
  https://doi.org/10.7717/peerj.7359

- **MaxBin 2.0** — Wu, Y.-W., Simmons, B. A. & Singer, S. W. MaxBin 2.0: an
  automated binning algorithm to recover genomes from multiple metagenomic
  datasets. *Bioinformatics* **32**, 605–607 (2016).
  https://doi.org/10.1093/bioinformatics/btv638

- **CONCOCT** — Alneberg, J. *et al.* Binning metagenomic contigs by coverage
  and composition. *Nature Methods* **11**, 1144–1146 (2014).
  https://doi.org/10.1038/nmeth.3103

- **DAS Tool** — Sieber, C. M. K. *et al.* Recovery of genomes from
  metagenomes via a dereplication, aggregation and scoring strategy.
  *Nature Microbiology* **3**, 836–843 (2018).
  https://doi.org/10.1038/s41564-018-0171-1

## MAG quality assessment

- **CheckM2** — Chklovski, A., Parks, D. H., Woodcroft, B. J. & Tyson, G. W.
  CheckM2: a rapid, scalable and accurate tool for assessing microbial genome
  quality using machine learning. *Nature Methods* **20**, 1203–1212 (2023).
  https://doi.org/10.1038/s41592-023-01940-w

- **MIMAG standard** — Bowers, R. M. *et al.* Minimum information about a
  single amplified genome (MISAG) and a metagenome-assembled genome (MIMAG) of
  bacteria and archaea. *Nature Biotechnology* **35**, 725–731 (2017).
  https://doi.org/10.1038/nbt.3893

## Dereplication

- **dRep** — Olm, M. R., Brown, C. T., Brooks, B. & Banfield, J. F. dRep: a
  tool for fast and accurate genomic comparisons that enables improved genome
  recovery from metagenomes through de-replication. *The ISME Journal* **11**,
  2864–2868 (2017). https://doi.org/10.1038/ismej.2017.126

## Taxonomic classification

- **GTDB-Tk** — Chaumeil, P.-A. *et al.* GTDB-Tk v2: memory friendly
  classification with the Genome Taxonomy Database. *Bioinformatics* **38**,
  5315–5316 (2022). https://doi.org/10.1093/bioinformatics/btac672

- **Kraken 2** — Wood, D. E., Lu, J. & Langmead, B. Improved metagenomic
  analysis with Kraken 2. *Genome Biology* **20**, 257 (2019).
  https://doi.org/10.1186/s13059-019-1891-0

- **Bracken** — Lu, J., Breitwieser, F. P., Thielen, P. & Salzberg, S. L.
  Bracken: estimating species abundance in metagenomics data. *PeerJ Computer
  Science* **3**, e104 (2017). https://doi.org/10.7717/peerj-cs.104

## Functional annotation

- **Prokka** — Seemann, T. Prokka: rapid prokaryotic genome annotation.
  *Bioinformatics* **30**, 2068–2069 (2014).
  https://doi.org/10.1093/bioinformatics/btu153

- **eggNOG-mapper** — Cantalapiedra, C. P., Hernández-Plaza, A., Letunic, I.,
  Bork, P. & Huerta-Cepas, J. eggNOG-mapper v2: functional annotation,
  orthology assignments, and domain prediction at the metagenomic scale.
  *Molecular Biology and Evolution* **38**, 5825–5829 (2021).
  https://doi.org/10.1093/molbev/msab293

- **Prodigal** — Hyatt, D. *et al.* Prodigal: prokaryotic gene recognition and
  translation initiation site identification. *BMC Bioinformatics* **11**, 119
  (2010). https://doi.org/10.1186/1471-2105-11-119

## Supporting utilities

- **SeqKit** — Shen, W. *et al.* SeqKit: a cross-platform and ultrafast
  toolkit for FASTA/Q file manipulation. *PLoS ONE* **11**, e0163962 (2016).
  https://doi.org/10.1371/journal.pone.0163962
