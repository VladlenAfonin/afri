import argparse
import logging
import os
import csv

from matplotlib import pyplot as plt
import scienceplots

from plot.config import config
from plot.logging import logging_mark


logger = logging.getLogger(__name__)


def parse_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "-p",
        "--party",
        help="create figure for party: prover, verifier  (default: prover)",
        default="prover",
        required=False,
        dest="party",
    )

    parser.add_argument(
        "--fri",
        help="FRI data",
        required=True,
        dest="fri_input_file",
    )

    parser.add_argument(
        "--afri",
        help="aFRI data",
        required=True,
        dest="afri_input_file",
    )

    parser.add_argument(
        "-o",
        "--out",
        "--output",
        help="output file",
        required=True,
        dest="output_file",
    )

    parser.add_argument(
        "-f",
        "--force",
        help="override everything it can to make the program run",
        required=False,
        action="store_true",
        dest="force",
    )

    parser.set_defaults(func=act)


@logging_mark(logger)
def act(args: argparse.Namespace) -> int:
    if (not args.force) and os.path.isfile(args.output_file):
        logger.error(
            "output file already exists: %s",
            args.output_file,
        )
        return 1

    if not os.path.isfile(args.fri_input_file):
        logger.error(
            "input file not found: %s",
            args.input_file,
        )
        return 1

    if not os.path.isfile(args.afri_input_file):
        logger.error(
            "input file not found: %s",
            args.input_file,
        )
        return 1

    logger.debug("got output_file = %s", args.output_file)
    logger.debug("got fri_input_file = %s", args.fri_input_file)
    logger.debug("got afri_input_file = %s", args.afri_input_file)

    log_ns = []
    fri_avgs = []
    afri_avgs = []

    with open(args.fri_input_file, "r") as input_file:
        input_reader = csv.DictReader(input_file)
        for row in input_reader:
            log_ns.append(int(row["benchmark"]))
            fri_avgs.append(int(row["avg"]) / (1e6 if args.party == "prover" else 1e6))

    with open(args.afri_input_file, "r") as input_file:
        input_reader = csv.DictReader(input_file)
        for row in input_reader:
            afri_avgs.append(int(row["avg"]) / (1e6 if args.party == "prover" else 1e6))

    plt.style.use(["science", "russian-font"])

    _, ax = plt.subplots()

    # INFO: X-scale is already log.
    if args.party == "prover":
        ax.set_yscale("log")

    ax.set_xlabel("Степень начального многочлена")
    ax.set_ylabel(
        "Время выполнения, мс" if args.party == "prover" else "Время выполнения, мс"
    )

    ax.plot(
        log_ns,
        fri_avgs,
        label=r"Доказывающий FRI" if args.party == "prover" else "Проверяющий FRI",
    )

    ax.plot(
        log_ns,
        afri_avgs,
        # label=r"$\mathcal{P}_{\textsf{aFRI}}$"
        label=r"Доказывающий aFRI" if args.party == "prover" else "Проверяющий aFRI",
    )

    xticks = ax.get_xticks()
    ax.set_xticklabels([f"$2^{{{x:.0f}}}$" for x in xticks])

    # ax.set_xticks([2**x for x in avgs])
    # ax.plot([2**x for x in initial_degree_logs], prover_times, label="Доказывающий")
    # ax.plot([2**x for x in initial_degree_logs], verifier_times, label="Проверяющий")
    ax.legend()
    # fig.subplots_adjust(bottom=0.15, left=0.14, top=0.94, right=0.94)

    plt.savefig(args.output_file, dpi=300)

    return 0
