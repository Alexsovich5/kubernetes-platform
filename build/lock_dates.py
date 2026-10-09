#!/usr/bin/env python3
"""Check that every revision in a glide.lock is dated on or before 2016-07-31.

Usage: lock_dates.py glide.lock

Each name/version pair is looked up on proxy.golang.org
(https://proxy.golang.org/<module>/@v/<version>.info). Exits 1 if any
revision is newer than the cutoff or any lookup fails.
"""
import datetime
import json
import re
import sys
import time
import urllib.error
import urllib.request

CUTOFF = datetime.date(2016, 7, 31)

# Packages whose original repository is gone and that glide fetches from a mirror.
MODULE_ALIASES = {
    "bitbucket.org/ww/goautoneg": "github.com/munnerz/goautoneg",
}


def parse_lock(path):
    """Return (name, version) pairs from the top-level imports of glide.lock.

    glide.lock is simple, glide-generated YAML; a line scanner avoids a
    PyYAML dependency on the host.
    """
    pairs = []
    section = None
    current = None
    for raw in open(path):
        line = raw.rstrip("\n")
        if re.match(r"^[A-Za-z]", line):
            section = line.split(":", 1)[0]
            continue
        if section not in ("imports", "testImports"):
            continue
        m = re.match(r"^- name: (\S+)\s*$", line)
        if m:
            current = [m.group(1), None]
            pairs.append(current)
            continue
        m = re.match(r"^  version: (\S+)\s*$", line)
        if m and current is not None:
            current[1] = m.group(1)
    return [(n, v) for n, v in pairs]


def escape(module):
    return re.sub(r"[A-Z]", lambda m: "!" + m.group(0).lower(), module)


def revision_time(module, version):
    url = "https://proxy.golang.org/%s/@v/%s.info" % (escape(module), version)
    last = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "lock_dates/1.0"})
            with urllib.request.urlopen(req, timeout=20) as r:
                info = json.load(r)
            return datetime.datetime.strptime(info["Time"][:10], "%Y-%m-%d").date()
        except urllib.error.HTTPError as e:
            last = "HTTP %d" % e.code
            if e.code in (404, 410):
                break
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            last = str(e)
        time.sleep(2)
    raise LookupError(last)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: lock_dates.py glide.lock\n")
        return 2
    pairs = parse_lock(argv[1])
    if not pairs:
        print("no imports found in %s" % argv[1])
        return 1
    problems = 0
    for name, version in pairs:
        module = MODULE_ALIASES.get(name, name)
        if not version:
            print("FAIL  %s: no version in lock" % name)
            problems += 1
            continue
        try:
            when = revision_time(module, version)
        except LookupError as e:
            print("FAIL  %s@%s: lookup failed (%s)" % (module, version, e))
            problems += 1
            continue
        if when > CUTOFF:
            print("FAIL  %s@%s: %s is after %s" % (module, version, when, CUTOFF))
            problems += 1
        else:
            print("ok    %s@%s: %s" % (module, version, when))
    print("%d checked, %d problems" % (len(pairs), problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
