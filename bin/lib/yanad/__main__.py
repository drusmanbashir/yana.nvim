import argparse

from .server import main


parser = argparse.ArgumentParser(description="Yana daemon")
parser.add_argument("--root", required=True)
parser.add_argument("--log-level", choices=("error", "warn", "info", "debug"))
args = parser.parse_known_args()[0]
main(args)
