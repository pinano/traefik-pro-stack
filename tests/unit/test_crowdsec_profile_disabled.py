import subprocess
import os

def test_makefile_crowdsec_enable_disabled():
    """
    Verify that Makefile correctly disables CrowdSec profile when CROWDSEC_ENABLE=false,
    even with quotes or whitespace variations.
    """
    for val in ["false", '"false"', "'false'", "FALSE", "False "]:
        proc = subprocess.run(
            ['make', f'CROWDSEC_ENABLE={val}', '-n', 'status'],
            cwd=os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')),
            capture_output=True,
            text=True
        )
        assert proc.returncode == 0
        # When CROWDSEC_ENABLE=false, '--profile crowdsec' should NOT be in the docker compose invocation
        assert '--profile crowdsec' not in proc.stdout, f"Failed for CROWDSEC_ENABLE={val}: {proc.stdout}"

def test_makefile_crowdsec_targets_disabled():
    """
    Verify that CrowdSec-specific make targets are blocked when CROWDSEC_ENABLE=false.
    """
    proc = subprocess.run(
        ['make', 'CROWDSEC_ENABLE=false', 'crowdsec-decisions'],
        cwd=os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')),
        capture_output=True,
        text=True
    )
    assert proc.returncode != 0
    assert "CrowdSec tasks are disabled because CROWDSEC_ENABLE=false" in proc.stdout or "CrowdSec tasks are disabled because CROWDSEC_ENABLE=false" in proc.stderr
