import argparse
import sys
import time

import psycopg

from nunchi.config import Settings
from nunchi.db import Conn
from nunchi.embed import Embedder, EmbedError, embedder_from_settings
from nunchi.worker.embedding import embed_missing
from nunchi.worker.freshness import run_once


def _embed_all(conn: Conn, embedder: Embedder) -> str:
    total = 0
    try:
        while n := embed_missing(conn, embedder):
            total += n
    except EmbedError as exc:
        return f"worker: embedded {total}, stopped: {exc}\n"
    return f"worker: embedded {total}\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m nunchi.worker")
    parser.add_argument("--once", action="store_true", help="run one pass and exit")
    parser.add_argument("--every", type=float, metavar="SECONDS", help="repeat with this pause")
    args = parser.parse_args(argv)
    if args.once == (args.every is not None):
        parser.error("give exactly one of --once or --every SECONDS")
    settings = Settings()
    embedder = embedder_from_settings(settings)
    url = settings.database_url.get_secret_value()
    with psycopg.connect(url) as conn:
        while True:
            result = run_once(conn)
            sys.stdout.write(f"worker: expired {result.expired}, stale {len(result.stale)}\n")
            if embedder is not None:
                sys.stdout.write(_embed_all(conn, embedder))
            sys.stdout.flush()
            if args.once:
                return 0
            time.sleep(args.every)


if __name__ == "__main__":
    sys.exit(main())
