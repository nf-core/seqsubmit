#!/bin/bash

nextflow main.nf \
   -profile singularity \
   --input assets/samplesheet.csv \
   --outdir test_output \
   --ena_genome_study_accession PRJEB98843 