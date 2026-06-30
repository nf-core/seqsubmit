//
// Subworkflow that validates input FASTA and filters out files with less than 2 contigs
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { FALINT                                } from '../../../modules/nf-core/falint/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow FASTA_VALIDATION {

    take:
    input_fasta  // [meta, fasta_file]

    main:

    // --------- Filter fasta to have more than 1 contig
    fasta_split = input_fasta.branch { meta, fasta ->
        valid: fasta.countFasta() > 1
        shorter_than_one_contig: true
    }

    // --------- Check fasta files are properly formatted
    FALINT (
        fasta_split.valid
    )

    valid_fastas = input_fasta.join(FALINT.out.success_log)
        .map { meta, fasta, _log ->
            [meta, fasta]
        }

    // Report failed
    invalid_fastas = fasta_split.valid
        .join(FALINT.out.error_log)
        .map { meta, fasta, _log ->
            [meta, fasta]
        }

    shorter_than_one_contig_fastas_report = fasta_split.shorter_than_one_contig.map { meta, fasta ->
        "${meta.id}\t${fasta}\tless_than_1_contig"
    }

    falint_report = invalid_fastas.map { meta, fasta ->
        "${meta.id}\t${fasta}\tfalint_failed"
    }

    shorter_than_one_contig_fastas_report
        .mix(falint_report)
        .collectFile(
            name: "${params.outdir}/${params.mode}/invalid_fastas.tsv",
            newLine: true,
            seed: "sample\tfasta\treason\n"
        )

    emit:
    valid_fastas    = valid_fastas
}
