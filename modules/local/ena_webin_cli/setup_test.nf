process GENERATE_TEST_DATA {
    label 'process_low'
    container "quay.io/biocontainers/ena-webin-cli:9.0.1--hdfd78af_1"

    input:
    path(manifest_template)

    output:
    path("*.manifest"), emit: test_manifest

    script:
    """
    timestamp="\$(date +%s)"

    sed -E "s/^(ASSEMBLYNAME\t[^\t]+)/\\1_\${timestamp}/" "${manifest_template}" > "lachnospira_eligens_dynamic_fixture.manifest"
    """
}
