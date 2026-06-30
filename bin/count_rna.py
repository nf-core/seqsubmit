#!/usr/bin/env python

## Originally written by Ekaterina Sakharova, modified by Sofia Ochkalova and released under the MIT license.
## See git repository (https://github.com/nf-core/seqsubmit) for full license text.


import argparse
import logging


# Expected rRNA gene lengths
EXPECTED_LENGTHS = {
    "16S_rRNA": 1450,
    "23S_rRNA": 2800,
    "5S_rRNA": 115,
    "18S_rRNA": 1800,
    "28S_rRNA": 4500,
    "5_8S_rRNA": 155,
}

AA = [
    "Ala",
    "Gly",
    "Pro",
    "Thr",
    "Val",
    "Ser",
    "Arg",
    "Leu",
    "Phe",
    "Asn",
    "Lys",
    "Asp",
    "Glu",
    "His",
    "Gln",
    "Ile",
    "Met",
    "Tyr",
    "Cys",
    "Trp",
]

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def parse_args():
    parser = argparse.ArgumentParser(
        description="Script parses tRNAscan-SE output and barrnap GFF output, and writes a decision "
        "of whether RNA genes are present in the genome. Decision is 'True' if number of tRNA genes "
        "is at least --trna-limit and 16S, 23S, and 5S rRNA genes have more than --rrna-limit percentage "
        "of gene length recovered, and 'False' otherwise."
    )
    parser.add_argument("-t", "--trna", dest="trna", help="trnas_stats.out from tRNAscan-SE",
                        required=True)
    parser.add_argument("-r", "--rrna", dest="rrna", help="GFF from barrnap",
                        required=True)
    parser.add_argument("-n", "--name", dest="name", help="FASTA Sequence identifier used for prediction",
                        required=True)
    parser.add_argument("-o", "--output", dest="output", help="Name of output file (default: rna_decision.tsv)",
                        default="rna_decision.tsv", required=False)
    parser.add_argument("--trna-limit", dest="trna_limit", help="Minimal required number of tRNA",
                        required=True, type=int)
    parser.add_argument("--rrna-limit", dest="rrna_limit", help="Minimum percentage of 16S, 23S, and 5S rRNA gene length recovered to count the gene as present.",
                        required=True, type=int)
    return parser.parse_args()


def parse_trna(trna_input):
    """Parses tRNAscan-SE output and counts number of tRNA genes with predicted amino acid in AA list.

    File example:
    (..more stuff at the beginning of the file..)
    Isotype / Anticodon Counts:

    Ala     : 5	  AGC:         GGC: 2       CGC:         TGC: 3
    Ser     : 5	  AGA:         GGA: 2       CGA: 1       TGA: 1       ACT:         GCT: 1
    Arg     : 7	  ACG: 4       GCG:         CCG: 1       TCG:         CCT: 1       TCT: 1
    Phe     : 2	  AAA:         GAA: 2
    Asn     : 4	  ATT:         GTT: 4
    Lys     : 6	                            CTT:         TTT: 6
    Supres  : 0	               CTA:         TTA:         TCA:
    """
    with open(trna_input, "r") as f:
        trnas = 0
        start_parsing = False
        for line in f:
            if "Isotype / Anticodon" in line:
                start_parsing = True
            elif start_parsing:
                cols = line.split()
                if len(cols) > 1:
                    aa_pred = line.split()[0]
                    counts = int(line.split()[2])
                    if aa_pred in AA:
                        trnas += counts
                        logging.info(f"Found {counts} tRNA genes for amino acid {aa_pred}")
    return trnas


def parse_rrna(rrna_input, rrna_limit):
    """Parses barrnap GFF output and counts 16S, 23S, and 5S rRNA genes that have more than --rrna-limit percentage of gene length recovered.

    File example:
    ##gff-version 3
    small  TransTermHP:2.09  terminator  189857  189880  100      +  .  product=Rho-independent terminator
    small  barrnap:1.6.0     operon      295463  298548  .        +  .  Name=rRNA operon;product=rRNA operon: rRNA-rRNA
    small  infernal:1.1.5    rRNA        295463  298336  4.8e-07  +  .  Name=23S_rRNA;Alias=LSU_rRNA_bacteria;Dbxref=Rfam:RF02541;product=23S ribosomal RNA
    small  infernal:1.1.5    rRNA        298432  298548  1.1e-13  +  .  Name=5S_rRNA;Alias=5S_rRNA;Dbxref=Rfam:RF00001;product=5S ribosomal RNA
    small  infernal:1.1.5    rRNA        456432  456548  1.0e-5   +  .  Name=5S_rRNA;Alias=5S_rRNA;Dbxref=Rfam:RF00001;product=5S ribosomal RNA
    """
    best_percentages = {}
    with open(rrna_input, 'r') as file_in:
        for line in file_in:
            if line.startswith("#"):
                continue
            line = line.strip().split("\t")
            gene_type = line[2]
            if gene_type == "rRNA":
                start = int(line[3])
                end = int(line[4])
                gene_length = end - start + 1

                # Extract gene name from the Name field
                gene_name = None
                for field in line[8].split(";"):
                    if field.startswith("Name="):
                        gene_name = field.split("=")[1]
                        break

                # Check if gene length meets the threshold
                # For now we only consider bacterial/archaeal rRNA genes
                if gene_name in ["16S_rRNA", "23S_rRNA", "5S_rRNA"]:
                    expected_length = EXPECTED_LENGTHS[gene_name]
                    percentage_recovered = (gene_length / expected_length) * 100
                    logging.info(f"Found {gene_name} with length {gene_length} bp, which is {percentage_recovered:.2f}% of expected length.")
                    if gene_name not in best_percentages or percentage_recovered > best_percentages[gene_name]:
                        best_percentages[gene_name] = percentage_recovered

    count = sum(1 for pct in best_percentages.values() if pct >= rrna_limit)
    return count

def main():
    args = parse_args()
    # parsing tRNA
    logging.info(f"Parsing tRNA genes from {args.trna}")
    trna_count = parse_trna(trna_input=args.trna)
    logging.info(f"Found {trna_count} tRNA in total")
    # parsing rRNA
    logging.info(f"Parsing rRNA genes from {args.rrna}")
    rrna_count = parse_rrna(rrna_input=args.rrna, rrna_limit=args.rrna_limit)
    logging.info(f"Found {rrna_count} rRNA subunit types in total")

    # rrna_count should be 3 to make sure all 3 rRNA genes are present
    decision = "Yes" if trna_count >= args.trna_limit and rrna_count == 3 else "No"
    logging.info(f"RNA presented: {decision}")

    with open(args.output, 'w') as file_out:
        file_out.write(f"{args.name}\t{str(decision)}")


if __name__ == "__main__":
    main()
