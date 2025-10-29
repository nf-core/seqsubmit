#!/bin/bash

nextflow main.nf \
   -profile docker \
   --input assets/samplesheet_coverM_test.csv \
   --outdir test_coverM_output \
   --ena_genome_study_accession PRJEB98843 \
   -resume