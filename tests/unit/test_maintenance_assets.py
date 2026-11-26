import re
import subprocess
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
MAINT_DIR = REPO_ROOT / "config" / "maintenance"
ASSETS_SCRIPT = REPO_ROOT / "scripts" / "init.d" / "04-assets.sh"


def _extract_maintenance_copy_snippet() -> str:
    content = ASSETS_SCRIPT.read_text(encoding="utf-8")
    start = content.index("# Maintenance page asset")
    end = content.index("\nmkdir -p ./config/traefik", start)
    return content[start:end]


def test_maintenance_dist_is_bilingual_and_self_contained():
    dist_file = MAINT_DIR / "index.html.dist"
    assert dist_file.exists(), "config/maintenance/index.html.dist must exist"

    html = dist_file.read_text(encoding="utf-8")
    assert "Servicio temporalmente no disponible" in html
    assert "Service temporarily unavailable" in html
    assert "503" not in html
    assert not re.search(r"https?://", html), "Default maintenance page must not depend on external URLs"


def test_maintenance_override_is_gitignored_and_mounted_as_directory():
    gitignore = (REPO_ROOT / ".gitignore").read_text(encoding="utf-8")
    assert "config/maintenance/index.html" in gitignore.splitlines()

    nginx_conf = (MAINT_DIR / "default.conf").read_text(encoding="utf-8")
    assert "try_files /index.html /index.html.dist =503;" in nginx_conf

    for compose_name in ("docker-compose-edge.yaml", "docker-compose-maintenance.yaml"):
        compose = yaml.safe_load((REPO_ROOT / compose_name).read_text(encoding="utf-8"))
        services = compose["services"]
        svc = services.get("error-pages") or services.get("maintenance")
        assert svc is not None
        assert "./config/maintenance:/etc/nginx/maintenance:ro" in svc["volumes"]


def test_assets_script_seeds_maintenance_html_without_overwriting(tmp_path):
    snippet = _extract_maintenance_copy_snippet()
    maint_dir = tmp_path / "config" / "maintenance"
    maint_dir.mkdir(parents=True)
    (maint_dir / "index.html.dist").write_text("DEFAULT_TEMPLATE", encoding="utf-8")

    # 1. Seeds index.html from .dist when missing
    proc1 = subprocess.run(["bash", "-c", snippet], cwd=str(tmp_path), capture_output=True, text=True)
    assert proc1.returncode == 0, proc1.stderr
    assert (maint_dir / "index.html").read_text(encoding="utf-8") == "DEFAULT_TEMPLATE"

    # 2. Preserves custom index.html without overwriting
    (maint_dir / "index.html").write_text("CUSTOM_USER_PAGE", encoding="utf-8")
    proc2 = subprocess.run(["bash", "-c", snippet], cwd=str(tmp_path), capture_output=True, text=True)
    assert proc2.returncode == 0, proc2.stderr
    assert (maint_dir / "index.html").read_text(encoding="utf-8") == "CUSTOM_USER_PAGE"
