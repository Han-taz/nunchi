import argparse
import sys
import time

import psycopg

from nunchi.config import Settings
from nunchi.db import Conn, open_pool
from nunchi.embed import Embedder, EmbedError, embedder_from_settings
from nunchi.extract import build_extractor
from nunchi.mattermost.__main__ import MattermostEnv
from nunchi.mattermost.client import Mattermost
from nunchi.mattermost.digest import Digest, DigestLimits, run_digest
from nunchi.mattermost.membership import refresh_memberships
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


def _digest_loop(args: argparse.Namespace) -> int:
    env = MattermostEnv()
    settings = Settings()
    client = Mattermost(env.mm_url, env.mm_bot_token.get_secret_value(), env.mm_site_url)
    digest = Digest(
        open_pool(settings),
        client,
        build_extractor(),
        env.nunchi_tenant_id,
        client.me()["id"],
        embedder_from_settings(settings),
        DigestLimits(args.digest_max_windows, args.digest_max_chars),
    )
    while True:
        sys.stdout.write(f"membership: refreshed {refresh_memberships(digest)}\n")
        sys.stdout.write(f"digest: {run_digest(digest)}\n")
        sys.stdout.flush()
        if args.once:
            return 0
        time.sleep(args.every)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m nunchi.worker")
    parser.add_argument("--once", action="store_true", help="run one pass and exit")
    parser.add_argument("--every", type=float, metavar="SECONDS", help="repeat with this pause")
    parser.add_argument("--digest", action="store_true", help="digest bound Mattermost channels")
    parser.add_argument(
        "--digest-max-windows", type=int, default=20, help="extractor calls per run"
    )
    parser.add_argument("--digest-max-chars", type=int, default=6000, help="characters per window")
    args = parser.parse_args(argv)
    if args.once == (args.every is not None):
        parser.error("give exactly one of --once or --every SECONDS")
    if args.digest:
        return _digest_loop(args)
    settings = Settings()
    embedder = embedder_from_settings(settings)
    url = settings.database_url.get_secret_value()
    with psycopg.connect(url) as conn:
        while True:
            result = run_once(conn)
            sys.stdout.write(
                f"worker: promoted {result.promoted}, replaced {result.replaced},"
                f" expired {result.expired}, stale {len(result.stale)}\n"
            )
            if embedder is not None:
                sys.stdout.write(_embed_all(conn, embedder))
            sys.stdout.flush()
            if args.once:
                return 0
            time.sleep(args.every)


if __name__ == "__main__":
    sys.exit(main())
