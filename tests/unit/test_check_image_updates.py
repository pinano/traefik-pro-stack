import os
import sys
import pytest
from pathlib import Path

# Add scripts directory to path to import functions directly
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', 'scripts')))

# We can import directly because check-image-updates.py has an if __name__ == "__main__": guard
try:
    import check_image_updates
except ImportError:
    # Handle the fact that the script has hyphens in the filename
    import importlib.util
    script_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', 'scripts', 'check-image-updates.py'))
    spec = importlib.util.spec_from_file_location("check_image_updates", script_path)
    check_image_updates = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(check_image_updates)


def test_parse_version():
    """Test semantic version parsing logic"""
    # Standard semver
    assert check_image_updates.parse_version("1.2.3") == (1, 2, 3, 0, "", "1.2.3")
    assert check_image_updates.parse_version("v2.0") == (2, 0, 0, 0, "", "v2.0")
    
    # Suffixes
    assert check_image_updates.parse_version("1.2.3-alpine") == (1, 2, 3, 0, "alpine", "1.2.3-alpine")
    assert check_image_updates.parse_version("3.1.4-rc.1") == (3, 1, 4, 0, "rc.1", "3.1.4-rc.1")


def test_is_prerelease():
    """Test prerelease and CI tag detection"""
    assert check_image_updates.is_prerelease("rc") is True
    assert check_image_updates.is_prerelease("beta") is True
    assert check_image_updates.is_prerelease("alpha") is True
    assert check_image_updates.is_prerelease("dev") is True
    assert check_image_updates.is_prerelease("nightly") is True
    
    # Numeric CI tags
    assert check_image_updates.is_prerelease("20230514") is True
    assert check_image_updates.is_prerelease("382947293") is True
    
    # Valid flavors
    assert check_image_updates.is_prerelease("alpine") is False
    assert check_image_updates.is_prerelease("slim") is False
    assert check_image_updates.is_prerelease("debian") is False
    assert check_image_updates.is_prerelease("") is False


def test_is_same_flavor():
    """Test that updates don't cross OS flavors (e.g. debian to alpine)"""
    current_alpine = check_image_updates.parse_version("1.0.0-alpine")
    current_slim = check_image_updates.parse_version("1.0.0-slim")
    current_none = check_image_updates.parse_version("1.0.0")
    
    # Alpine should only match alpine
    assert check_image_updates.is_same_flavor(current_alpine, "1.1.0-alpine") is True
    assert check_image_updates.is_same_flavor(current_alpine, "1.1.0-alpine3.18") is True
    assert check_image_updates.is_same_flavor(current_alpine, "1.1.0-slim") is False
    assert check_image_updates.is_same_flavor(current_alpine, "1.1.0") is False
    
    # No flavor should only match no flavor
    assert check_image_updates.is_same_flavor(current_none, "1.1.0") is True
    assert check_image_updates.is_same_flavor(current_none, "1.1.0-alpine") is False
