import os
import re
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RESTART_SCRIPT = REPO_ROOT / "scripts" / "restart-internal.sh"
MAKEFILE = REPO_ROOT / "Makefile"


def _extract_tag_resolver_snippet() -> str:
    content = RESTART_SCRIPT.read_text(encoding="utf-8")
    start = content.index('for _svc_pair in "dashboard:STACK_DASHBOARD_TAG"')
    end = content.index("\n# Audit config for drift", start)
    return content[start:end]


def test_restart_internal_passes_no_build():
    content = RESTART_SCRIPT.read_text(encoding="utf-8")
    up_lines = [
        line.strip()
        for line in content.splitlines()
        if "up -d" in line and not line.strip().startswith("#")
    ]
    assert len(up_lines) == 1
    assert "--no-build" in up_lines[0]
    assert "--no-recreate" in up_lines[0]
    assert "--remove-orphans" in up_lines[0]


def test_tag_resolver_uses_running_container_image_when_env_tag_missing(tmp_path):
    snippet = _extract_tag_resolver_snippet()
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake_docker = bin_dir / "docker"
    fake_docker.write_text(
        "#!/usr/bin/env bash\n"
        "if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ]; then\n"
        "    exit 1\n"
        "fi\n"
        "if [ \"$1\" = \"ps\" ]; then\n"
        "    if [[ \"$*\" == *\"service=dashboard\"* ]]; then\n"
        "        echo 'stack-dashboard:v2026.11.26-abc1234'\n"
        "    elif [[ \"$*\" == *\"service=watchdog\"* ]]; then\n"
        "        echo 'stack-watchdog:v2026.11.26-abc1234'\n"
        "    fi\n"
        "    exit 0\n"
        "fi\n"
        "exit 1\n",
        encoding="utf-8",
    )
    fake_docker.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env.pop("STACK_DASHBOARD_TAG", None)
    env.pop("STACK_WATCHDOG_TAG", None)

    proc = subprocess.run(
        [
            "bash",
            "-eo",
            "pipefail",
            "-c",
            snippet + '\necho "DASH=$STACK_DASHBOARD_TAG|WATCH=$STACK_WATCHDOG_TAG"',
        ],
        env=env,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    assert "DASH=v2026.11.26-abc1234|WATCH=v2026.11.26-abc1234" in proc.stdout


def test_tag_resolver_falls_back_to_docker_images_when_no_container(tmp_path):
    snippet = _extract_tag_resolver_snippet()
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake_docker = bin_dir / "docker"
    fake_docker.write_text(
        "#!/usr/bin/env bash\n"
        "if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ]; then\n"
        "    exit 1\n"
        "fi\n"
        "if [ \"$1\" = \"ps\" ]; then\n"
        "    exit 0\n"
        "fi\n"
        "if [ \"$1\" = \"images\" ]; then\n"
        "    echo '<none>'\n"
        "    echo 'v2026.11.26-def5678'\n"
        "    exit 0\n"
        "fi\n"
        "exit 1\n",
        encoding="utf-8",
    )
    fake_docker.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env["STACK_DASHBOARD_TAG"] = "stale-tag"
    env.pop("STACK_WATCHDOG_TAG", None)

    proc = subprocess.run(
        [
            "bash",
            "-eo",
            "pipefail",
            "-c",
            snippet + '\necho "DASH=$STACK_DASHBOARD_TAG|WATCH=$STACK_WATCHDOG_TAG"',
        ],
        env=env,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    assert "DASH=v2026.11.26-def5678|WATCH=v2026.11.26-def5678" in proc.stdout


def test_tag_resolver_keeps_existing_valid_tag(tmp_path):
    snippet = _extract_tag_resolver_snippet()
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake_docker = bin_dir / "docker"
    fake_docker.write_text(
        "#!/usr/bin/env bash\n"
        "if [ \"$1\" = \"image\" ] && [ \"$2\" = \"inspect\" ] && [ \"$3\" = \"stack-dashboard:v2026.11.26-good\" ]; then\n"
        "    exit 0\n"
        "fi\n"
        "exit 1\n",
        encoding="utf-8",
    )
    fake_docker.chmod(0o755)

    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env["STACK_DASHBOARD_TAG"] = "v2026.11.26-good"
    env.pop("STACK_WATCHDOG_TAG", None)

    proc = subprocess.run(
        [
            "bash",
            "-eo",
            "pipefail",
            "-c",
            snippet + '\necho "DASH=$STACK_DASHBOARD_TAG"',
        ],
        env=env,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    assert "DASH=v2026.11.26-good" in proc.stdout


def test_makefile_rebuild_preserves_env_inode_and_builds_before_up(tmp_path):
    makefile_text = MAKEFILE.read_text(encoding="utf-8")
    assert "sed -i" not in makefile_text
    assert "$(DOCKER_COMPOSE) build $$SVCS" in makefile_text
    assert "$(DOCKER_COMPOSE) up -d --no-build --force-recreate $$SVCS" in makefile_text
    assert makefile_text.index("$(DOCKER_COMPOSE) build $$SVCS") < makefile_text.index(
        "$(DOCKER_COMPOSE) up -d --no-build --force-recreate $$SVCS"
    )

    # Extract and run the exact Python one-liner used in Makefile against a temp .env
    m = re.search(r"python3 -c '([^']+)'", makefile_text)
    assert m is not None
    py_code = m.group(1).replace("$$", "$")

    env_file = tmp_path / ".env"
    env_file.write_text("DOMAIN=example.com\nSTACK_DASHBOARD_TAG=old-tag\n", encoding="utf-8")
    inode_before = env_file.stat().st_ino

    proc = subprocess.run(
        ["python3", "-c", py_code, "STACK_DASHBOARD_TAG", "v2026.11.26-newsha"],
        cwd=str(tmp_path),
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    assert env_file.stat().st_ino == inode_before
    assert "STACK_DASHBOARD_TAG=v2026.11.26-newsha" in env_file.read_text(encoding="utf-8")

    # Also test appending when variable is absent
    proc2 = subprocess.run(
        ["python3", "-c", py_code, "STACK_WATCHDOG_TAG", "v2026.11.26-newsha"],
        cwd=str(tmp_path),
        capture_output=True,
        text=True,
    )
    assert proc2.returncode == 0, proc2.stderr
    assert env_file.stat().st_ino == inode_before
    content = env_file.read_text(encoding="utf-8")
    assert "STACK_DASHBOARD_TAG=v2026.11.26-newsha" in content
    assert "STACK_WATCHDOG_TAG=v2026.11.26-newsha" in content
