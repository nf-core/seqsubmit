//
// Subworkflow that calculates tRNA and rRNA and make a decision od MIMAG standard
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { BARRNAP        } from '../../modules/nf-core/barrnap'
include { TRNASCANSE     } from '../../modules/nf-core/trnascanse'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow RNA_DETECTION {
    take:
    fasta

    main:

    ch_versions = Channel.empty()
    BARRNAP(
        fasta.map {id, fasta -> [id, fasta, "bac"]}
    )

    TRNASCANSE(
        fasta
    )

}