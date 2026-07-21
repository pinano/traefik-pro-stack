import os
import shutil
import subprocess
import tempfile
from pathlib import Path

SCRIPT_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', 'scripts', 'validate-env.py'))

def test_validate_env_sync(tmp_path):
    """
    Tests that validate-env.py correctly synchronizes .env with .env.dist
    """
    env_dist = tmp_path / '.env.dist'
    env_file = tmp_path / '.env'
    
    # 1. Create a mock .env.dist with new variables
    env_dist.write_text(
        "# Global Settings\n"
        "DOMAIN=example.com\n"
        "NEW_VAR=default_value\n"
        "export EXPORTED_VAR=true\n"
    )
    
    # 2. Create a mock .env missing the new variables but with custom ones
    env_file.write_text(
        "DOMAIN=mydomain.com\n"
        "CUSTOM_VAR=my_custom_value\n"
    )
    
    # Run the sync command
    result = subprocess.run(
        ['python3', SCRIPT_PATH, '--sync'],
        cwd=str(tmp_path),
        capture_output=True,
        text=True
    )
    
    assert result.returncode == 0, f"Sync failed: {result.stderr}"
    
    # Check the resulting .env
    content = env_file.read_text()
    
    # Existing variable should NOT be overwritten
    assert "DOMAIN=mydomain.com" in content
    assert "DOMAIN=example.com" not in content
    
    # New variables should be added
    assert "NEW_VAR=default_value" in content
    assert "export EXPORTED_VAR=true" in content
    
    # Custom variable should be preserved
    assert "CUSTOM_VAR=my_custom_value" in content
    
    # Backup should be created
    backup_file = tmp_path / '.env.bak'
    assert backup_file.exists()


def test_validate_env_missing_keys(tmp_path):
    """
    Tests that validate-env.py fails if keys are missing and sync is not used.
    """
    env_dist = tmp_path / '.env.dist'
    env_file = tmp_path / '.env'
    
    env_dist.write_text("DOMAIN=example.com\nMISSING_KEY=123\n")
    env_file.write_text("DOMAIN=example.com\n")
    
    result = subprocess.run(
        ['python3', SCRIPT_PATH],
        cwd=str(tmp_path),
        capture_output=True,
        text=True
    )
    
    assert result.returncode == 1, "Script should have failed due to missing keys"
    assert "MISSING_KEY" in result.stdout
