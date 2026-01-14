import argparse
import logging
import logging.config
import sys

import afri.cli.run
import afri.logging


logger = logging.getLogger(__name__)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="aFRI Python supporting code",
    )
    sub_parsers = parser.add_subparsers()

    run_parser = sub_parsers.add_parser("run", help="run application")
    afri.cli.run.parse_args(run_parser)

    return parser.parse_args()


def main() -> int:
    logging.config.dictConfig(afri.logging.default_config)
    logger.debug("begin application")

    args = parse_args()

    if args.func is None:
        logger.error("no function to execute")
        logger.debug("end application")
        return 1

    args.func(args)

    logger.debug("end application")
    return 0


if __name__ == "__main__":
    result = main()
    sys.exit(result)
