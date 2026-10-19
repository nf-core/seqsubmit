process EUKCC_SINGLE {

    container 'community.wave.seqera.io/library/python_metaeuk_pplacer_epa-ng_pruned:0b7ea587ebcad440'
    tag "${meta.id}"

    input:
    tuple val(meta), path(fasta)
    tuple val(meta_db), path(eukcc_db)

    output:
    tuple val(meta), path("*_eukcc_results/*eukcc.csv"), optional: true, emit: eukcc_csv
    tuple val("${task.process}"), val('eukcc'), eval('eukcc -v 2>&1 | grep -oE "[0-9]+\\.[0-9]+\\.[0-9]+" | head -n1'), emit: versions_eukcc, topic: versions
    tuple val("${task.process}"), val('metaeuk'), eval('metaeuk -h 2>&1 | grep "Version" | sed "s/.*Version: //"'), emit: versions_metaeuk, topic: versions
    tuple val("${task.process}"), val('pplacer'), eval ('pplacer --version'), emit: versions_pplacer, topic: versions

    script:
    def args   = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"

    """
    # EukCC exit codes:
    #   201 - no marker genes found, 204 - MetaEuk predicted zero proteins: not an error, genome has no estimate
    #   any other non-zero code (e.g. 1, 200, 202, 203, 222) is a real failure
    set +e
    eukcc single \\
        ${args} \\
        --db ${eukcc_db} \\
        --out ${prefix}_eukcc_results \\
        --threads ${task.cpus} \\
        ${fasta}
    exit_code=\$?
    set -e

    case \$exit_code in
        0)
            ;;
        201|204)
            echo "EukCC exited with code \$exit_code: no completeness estimate for ${prefix}" >&2
            ;;
        *)
            echo "EukCC failed with exit code \$exit_code" >&2
            exit \$exit_code
            ;;
    esac
    """

    stub:
    def args   = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    printf 'genome,completeness,contamination,ncbi_lng\\n${meta.id},90.0,1.0,1-131567-2759-33154-4751\\n' > ${meta.id}_eukcc.csv
    """
}
