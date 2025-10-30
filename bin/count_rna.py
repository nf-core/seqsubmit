#!/usr/bin/env python

# This file is part of MGnify genome analysis pipeline.
#
# MGnify genome analysis pipeline is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# MGnify genome analysis pipeline is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with MGnify genome analysis pipeline. If not, see <https://www.gnu.org/licenses/>.


import argparse

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

def parse_args():
    parser = argparse.ArgumentParser(description="Script detects counts of tRNA and rRNA")
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
    parser.add_argument("--rrna-limit", dest="rrna_limit", help="Minimal required number of tRNA",
                        required=True, type=int)
    return parser.parse_args()


def parse_trna(trna_input):
    with open(trna_input, "r") as f:
        trnas = 0
        flag = 0
        for line in f:
            if "Isotype / Anticodon" in line:
                flag = 1
            elif flag == 1:
                cols = line.split()
                if len(cols) > 1:
                    aa_pred = line.split(":")[0].split()[0]
                    counts = int(line.split(":")[1].split()[0])
                    if aa_pred in AA:
                        trnas += counts
    return trnas


def parse_rrna(rrna_input):
    count = 0
    with open(rrna_input, 'r') as file_in:
        for line in file_in:
            if 'rRNA' in line:
                count+=1
    return count

def main():
    args = parse_args()
    # parsing tRNA
    trna_count = parse_trna(trna_input=args.trna)
    print(f"Found {trna_count} tRNA")
    # parsing rRNA
    rrna_count = parse_rrna(rrna_input=args.rrna)
    print(f"Found {rrna_count} rRNA")

    decision = "Yes" if trna_count >= int(args.trna_limit) and rrna_count >= int(args.rrna_limit) else "No"
    print(f"RNA presented: {decision}")

    with open(args.output, 'w') as file_out:
        file_out.write(f"{args.name}\t{str(decision)}")


if __name__ == "__main__":
    main()
