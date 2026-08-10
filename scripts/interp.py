"""Run under an interpreter that can actually see the distro's bindings.

Every binding these helpers need — libdnf5, python-apt, pyalpm, PyGObject —
is installed by the distribution into the system interpreter's site-packages
and nowhere else. The helpers are started as `python3 <script>`, which is
whatever `python3` means on the caller's PATH: a pyenv shim, a uv or conda
environment, an activated virtualenv. In any of those the import fails while
the package is perfectly well installed, and the honest-looking report
"python3-libdnf5 is missing" is then simply wrong.

So: if the binding cannot be imported here, hand the same command to a system
interpreter that can. Nothing is installed, nothing is changed; the process is
replaced, so the caller's stdout and exit code work as before.
"""

import glob
import os
import subprocess
import sys


def _candidates():
    """System interpreters, newest first.

    The current executable is not excluded by path: a virtualenv's python3 is
    usually a symlink to the very same binary, and what differs is the
    environment it starts in, not the file. Whether a candidate helps is
    decided by asking it, below.
    """
    found = []
    for pattern in ("/usr/bin/python3", "/usr/bin/python3.*"):
        for path in sorted(glob.glob(pattern), reverse=True):
            # python3.13-config and friends are not interpreters
            if not os.access(path, os.X_OK) or "-" in os.path.basename(path):
                continue
            if path not in found:
                found.append(path)
    return found


def ensure(module):
    """Re-exec under an interpreter that can import `module`, if this one cannot.

    Returns quietly when the import already works, or when no better
    interpreter exists — the caller reports that in its own protocol.
    """
    try:
        __import__(module)
        return
    except ImportError:
        pass

    script = os.path.abspath(sys.argv[0])
    if not os.path.isfile(script):
        return
    # A virtualenv is inherited through the environment, so the replacement has
    # to start outside it — otherwise the candidate lands in the same place
    env = dict(os.environ)
    for name in ("VIRTUAL_ENV", "PYTHONHOME", "PYTHONPATH", "CONDA_PREFIX"):
        env.pop(name, None)
    for candidate in _candidates():
        try:
            probe = subprocess.run([candidate, "-c", "import " + module],
                                   capture_output=True, timeout=20, env=env)
        except (OSError, subprocess.SubprocessError):
            continue
        if probe.returncode != 0:
            continue
        try:
            os.execve(candidate, [candidate, script] + sys.argv[1:], env)
        except OSError:
            continue


def describe():
    """Which interpreter is speaking, for a report that has to be believed."""
    return "%s (Python %s)" % (sys.executable or "python3",
                               ".".join(str(part) for part in sys.version_info[:3]))
