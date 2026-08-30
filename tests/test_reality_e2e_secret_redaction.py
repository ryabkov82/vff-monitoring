#!/usr/bin/env python3
"""Reality E2E credentials must not be loop-item facts or Ansible stdout."""

from __future__ import annotations

from pathlib import Path
import unittest

import yaml

REPO = Path(__file__).resolve().parents[1]
ROLE = REPO / "ansible/roles/reality_e2e"
TASKS_DIR = ROLE / "tasks"
TEMPLATES_DIR = ROLE / "templates"

SECRET_TASKS = (
    "Reality E2E | Assert shared secrets are provided (effective per node)",
    "Reality E2E | Render JSON profiles (by profile type)",
)

COMPUTE_TASK = "Reality E2E | Compute effective settings per node"

SECRET_KEYS = ("uuid", "public_key", "short_id", "shared_effective")


def _load_yaml(path: Path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _iter_tasks(docs, path: Path):
    if docs is None:
        return
    if isinstance(docs, dict):
        docs = [docs]
    for item in docs:
        if not isinstance(item, dict):
            continue
        yield path, item
        for key in ("block", "rescue", "always"):
            if key in item:
                yield from _iter_tasks(item[key], path)


def _all_role_tasks():
    tasks = []
    for path in sorted(TASKS_DIR.glob("*.yml")):
        tasks.extend(_iter_tasks(_load_yaml(path), path))
    return tasks


def _task_by_name(name: str) -> dict:
    for _path, task in _all_role_tasks():
        if task.get("name") == name:
            return task
    raise AssertionError(f"task not found: {name}")


def _dump(value) -> str:
    return yaml.safe_dump(value, sort_keys=False)


class RealityE2ESecretRedactionTests(unittest.TestCase):
    def test_nodes_eff_compute_does_not_store_shared_effective(self) -> None:
        task = _task_by_name(COMPUTE_TASK)
        body = _dump(task.get("ansible.builtin.set_fact") or task.get("set_fact") or {})
        self.assertNotIn("shared_effective", body)
        for key in ("uuid", "public_key", "short_id"):
            self.assertNotIn(f"'{key}'", body)
            self.assertNotIn(f"{key}:", body)

    def test_secret_bearing_tasks_have_no_log(self) -> None:
        for name in SECRET_TASKS:
            task = _task_by_name(name)
            self.assertIs(task.get("no_log"), True, msg=name)

    def test_secret_task_vars_are_not_taken_from_loop_item(self) -> None:
        assert_task = _task_by_name(SECRET_TASKS[0])
        render = _task_by_name(SECRET_TASKS[1])
        self.assertIn("_e2e_shared", assert_task.get("vars") or {})
        self.assertIn("eff_shared", render.get("vars") or {})
        self.assertNotIn("shared_effective", _dump(assert_task.get("vars")))
        self.assertNotIn("item.reality.shared_effective", _dump(render.get("vars")))
        self.assertIn("combine(", _dump(assert_task["vars"]["_e2e_shared"]))
        self.assertIn("combine(", _dump(render["vars"]["eff_shared"]))

    def test_loop_items_without_no_log_are_not_secret_bearing(self) -> None:
        for path, task in _all_role_tasks():
            if task.get("no_log") is True:
                continue
            dumped = _dump(task)
            if "reality_e2e_nodes_eff" not in dumped and "loop:" not in dumped:
                continue
            self.assertNotIn(
                "shared_effective",
                dumped,
                msg=f"{path.name}: {task.get('name')}",
            )
            self.assertNotIn("item.reality.shared_effective", dumped)

    def test_ssh_config_parse_runs_in_check_mode(self) -> None:
        task = _task_by_name(
            "Reality E2E | Parse ~/.ssh/config on controller (Host -> HostName)"
        )
        self.assertIs(task.get("check_mode"), False)
        self.assertIs(task.get("changed_when"), False)

    def test_templates_use_eff_shared_not_group_vault_fields(self) -> None:
        for path in sorted(TEMPLATES_DIR.glob("*")):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn(
                "reality_e2e_shared.uuid",
                text,
                msg=path.name,
            )
            self.assertNotIn("reality_e2e_shared.public_key", text, msg=path.name)
            self.assertNotIn("reality_e2e_shared.short_id", text, msg=path.name)
            if path.suffix == ".j2" and "profile" in path.name and path.name.endswith(".json.j2"):
                self.assertIn("eff_shared", text, msg=path.name)


if __name__ == "__main__":
    unittest.main()
