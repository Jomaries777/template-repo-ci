"""`python -m app`: serve on $PORT (default 8080)."""

import os
import signal
import sys

from app.server import create_server


def main() -> None:
    server = create_server(port=int(os.environ.get("PORT", "8080")))
    # Containers stop with SIGTERM: shut down cleanly instead of being killed.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
