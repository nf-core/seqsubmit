//
// Subworkflow that calculates tRNA and rRNA and make a decision od MIMAG standard
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { COUNT_RNA      } from '../../modules/local/count_rna'

include { BARRNAP        } from '../../modules/nf-core/barrnap'
include { TRNASCANSE     } from '../../modules/nf-core/trnascanse'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow RNA_DETECTION {
    take:
    fasta                // channel: [ val(meta), path(fasta) ]
    min_trna_count       // val: int - minimum number of tRNAs required to pass MIMAG standard (e.g. 18)
    min_rrna_percentage  // val: float - minimum percentage of rRNA genes required to pass MIMAG standard (e.g. 75)

    main:

    ch_versions = channel.empty()
    BARRNAP(
        fasta.map {id, fasta -> [id, fasta, "bac"]}
    )
    ch_versions = ch_versions.mix( BARRNAP.out.versions )

    TRNASCANSE(
        fasta
    )
    ch_versions = ch_versions.mix( TRNASCANSE.out.versions )

    COUNT_RNA(
        TRNASCANSE.out.stats.join(BARRNAP.out.gff),
        min_trna_count,
        min_rrna_percentage
    )
    ch_versions = ch_versions.mix( COUNT_RNA.out.versions )

    emit:
    rna_detected   = COUNT_RNA.out.rna_decision
    versions       = ch_versions
}
