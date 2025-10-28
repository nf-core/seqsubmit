#!/bin/bash

nextflow main.nf \
   -profile docker \
   --input assets/samplesheet.csv \
   --outdir test_output \
   --ena_genome_study_accession PRJEB98843 \
   --centre_name "TEST_CENTER" \
   -resume