#!/usr/bin/env python3
"""Build a NoCloud cloud-init seed ISO (volume id: cidata)."""
import sys
from pathlib import Path

try:
    import pycdlib
except ImportError:
    print("pycdlib required: pip install pycdlib", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <cloud-init-dir> <output.iso>", file=sys.stderr)
        return 2
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=3, joliet=3, rock_ridge="1.09", vol_ident="cidata")
    iso.add_file(str(src / "user-data"), iso_path="/user-data", rr_name="user-data")
    iso.add_file(str(src / "meta-data"), iso_path="/meta-data", rr_name="meta-data")
    iso.write(str(out))
    iso.close()
    print(f"Wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
