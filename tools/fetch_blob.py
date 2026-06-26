#!/usr/bin/env python3
import os
import sys
import urllib.request


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: fetch_blob.py <cid_hex> <out_path>", file=sys.stderr)
        return 1
    tmpl = os.environ.get("CHAT1_FETCH_TEMPLATE", "http://127.0.0.1:8090/%s")
    url = tmpl % sys.argv[1]
    urllib.request.urlretrieve(url, sys.argv[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
