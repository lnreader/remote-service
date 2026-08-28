from pathlib import Path

import pytest

from src.server.storage import safe_backup_path


def test_safe_backup_path_accepts_nested_backup(tmp_path: Path):
    actual = safe_backup_path(tmp_path, "novels.backup", "nested/data.zip")
    assert actual == (tmp_path / "novels.backup" / "nested/data.zip").resolve()


@pytest.mark.parametrize(
    ("backup_name", "filename"),
    [
        ("../outside.backup", "data.zip"),
        ("safe.backup", "../../outside.zip"),
        ("/tmp/outside.backup", "data.zip"),
    ],
)
def test_safe_backup_path_rejects_escape(tmp_path: Path, backup_name: str, filename: str):
    with pytest.raises(ValueError):
        safe_backup_path(tmp_path, backup_name, filename)
