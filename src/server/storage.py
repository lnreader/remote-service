"""Storage helpers shared by the LNReader remote-service API."""

from __future__ import annotations

import json
import os
from pathlib import Path

DEFAULT_APP_DIR = Path.home() / ".LNReader"


def get_workspace() -> Path:
    """Return the configured LNReader backup workspace.

    Containers may set LNREADER_STORAGE_DIR directly. The desktop/CLI behavior
    remains compatible with upstream by falling back to ~/.LNReader/config.json.
    """
    override = os.environ.get("LNREADER_STORAGE_DIR")
    if override:
        return Path(override).expanduser().resolve()

    config_path = DEFAULT_APP_DIR / "config.json"
    with config_path.open("r", encoding="utf-8") as handle:
        config = json.load(handle)
    return Path(config["workspace"]).expanduser().resolve()


def safe_backup_path(workspace: Path, backup_name: str, filename: str | None = None) -> Path:
    """Resolve a backup path while preventing escape from the workspace."""
    root = workspace.resolve()
    target = root / backup_name
    if filename is not None:
        target = target / filename
    target = target.resolve()

    try:
        target.relative_to(root)
    except ValueError as exc:
        raise ValueError("Backup path escapes the configured workspace") from exc

    return target
