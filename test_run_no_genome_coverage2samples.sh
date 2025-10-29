#!/bin/bash

nextflow main.nf \
   -profile docker \
   --input assets/samplesheet_2_samples.csv \
   --outdir test_output \
   --ena_genome_study_accession PRJEB98843 \
   -resume