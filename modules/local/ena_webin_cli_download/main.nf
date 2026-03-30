process ENA_WEBIN_CLI_DOWNLOAD {
    label 'process_single'

    input:
    val(version)

    output:
    path("webin-cli-*.jar"), emit: webin_cli_jar

    when:
    task.ext.when == null || task.ext.when

    script:

    """
    wget https://github.com/enasequence/webin-cli/releases/download/${version}/webin-cli-${version}.jar
    """

    stub:
    """
    touch webin-cli-stub.jar
    """
}
