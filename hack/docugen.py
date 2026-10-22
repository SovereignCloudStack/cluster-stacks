#!/usr/bin/env python3

"""
Generate markdown documentation from ClusterClass variable definitions.

Renders the cluster-class Helm template, parses the topology variables
(openAPIV3Schema), and outputs a markdown table of all configurable options.

Usage:
    ./hack/docugen.py [stack-dir]
    ./hack/docugen.py [stack-dir] --version 1.35 --output docs/configuration.md
    ./hack/docugen.py [stack-dir] --template hack/config-template.md
    ./hack/docugen.py [stack-dir] --matrix
    ./hack/docugen.py [stack-dir] --dry-run

If <stack-dir> is omitted, it is derived from $PROVIDER and $CLUSTER_STACK
(default: providers/openstack/scs). Without --version, the highest 1-* version
directory is used.

For backwards compatibility, a direct version directory like
providers/openstack/scs/1-35 is also accepted.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

import yaml


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent


def generate_row(columns: list) -> str:
    """Generate a markdown table row from a list of column values."""
    return "|" + "|".join(str(c) for c in columns) + "|"


def parse_variable(var: dict) -> list:
    """Parse a simple variable (string, boolean, integer, array) into table columns."""
    name = var["name"]
    required = var.get("required", False)
    schema = var["schema"]["openAPIV3Schema"]

    var_type = schema["type"]
    default = schema.get("default", "")
    example = schema.get("example", "")
    description = schema.get("description", "TODO").replace("\n", "<br />")

    if var_type == "string":
        default = f'"{default}"'
        example = f'"{example}"'
    else:
        default = str(default)
        example = str(example)

    return [f"`{name}`", var_type, default, example, description, str(required)]


def parse_object(var: dict) -> list:
    """Parse an object variable into multiple table rows (one per property)."""
    name = var["name"]
    props = var["schema"]["openAPIV3Schema"]["properties"]
    rows = []

    for prop_name, prop_schema in props.items():
        rows.append([
            f"`{name}.{prop_name}`",
            prop_schema["type"],
            prop_schema.get("default", ""),
            prop_schema.get("example", ""),
            prop_schema.get("description", "TODO"),
            "",
        ])

    return rows


def render_cluster_class(stack_dir: Path) -> dict:
    """Render the cluster-class Helm template and return parsed YAML."""
    cluster_class_dir = stack_dir / "cluster-class"
    if not cluster_class_dir.exists():
        print(f"cluster-class directory not found: {cluster_class_dir}", file=sys.stderr)
        sys.exit(1)

    result = subprocess.run(
        ["helm", "template", "docugen", str(cluster_class_dir),
         "-s", "templates/cluster-class.yaml"],
        capture_output=True, check=False,
    )

    if result.returncode != 0:
        print(f"helm template failed:\n{result.stderr.decode()}", file=sys.stderr)
        sys.exit(1)

    return yaml.safe_load(result.stdout.decode("utf-8"))


def resolve_base_dir(stack_dir: Path | None) -> Path:
    """Resolve the stack base directory from CLI input or environment."""
    if stack_dir is None:
        stack_dir = Path(
            f"providers/{os.environ.get('PROVIDER', 'openstack')}/{os.environ.get('CLUSTER_STACK', 'scs')}"
        )

    if not stack_dir.is_absolute():
        stack_dir = REPO_ROOT / stack_dir

    return stack_dir.resolve()


def resolve_version_dir(stack_dir: Path | None, version: str | None) -> tuple[Path, Path]:
    """Resolve stack base dir and concrete version dir."""
    resolved_input = resolve_base_dir(stack_dir)

    if resolved_input.name.startswith("1-") and (resolved_input / "cluster-class").exists():
        return resolved_input.parent, resolved_input

    stack_base = resolved_input
    if not stack_base.exists():
        print(f"Stack base directory not found: {stack_base}", file=sys.stderr)
        sys.exit(1)

    if version:
        version_dir = stack_base / version.replace(".", "-")
        if version_dir.exists():
            return stack_base, version_dir
        print(f"Version directory not found: {version_dir}", file=sys.stderr)
        sys.exit(1)

    candidates = sorted(
        (path for path in stack_base.glob("1-*") if path.is_dir()),
        key=lambda path: int(path.name.split("-", 1)[1]),
    )
    if not candidates:
        print(f"No version directories found in: {stack_base}", file=sys.stderr)
        sys.exit(1)

    return stack_base, candidates[-1]


def generate_table(template: dict) -> str:
    """Generate a markdown table from ClusterClass topology variables."""
    rows = [
        "|Name|Type|Default|Example|Description|Required|",
        "|----|----|-------|-------|-----------|--------|",
    ]

    for var in template["spec"]["variables"]:
        var_type = var["schema"]["openAPIV3Schema"]["type"]
        if var_type == "object":
            for row in parse_object(var):
                rows.append(generate_row(row))
        else:
            rows.append(generate_row(parse_variable(var)))

    return "\n".join(rows)


def main():
    parser = argparse.ArgumentParser(
        description="Generate docs from ClusterClass variables",
    )
    parser.add_argument(
        "stack_dir", type=Path, nargs="?", default=None,
        help="Path to the cluster stack base directory or a direct 1-XX version directory",
    )
    parser.add_argument(
        "--version", type=str, default=None,
        help="Kubernetes minor version to document (default: highest 1-* directory)",
    )
    parser.add_argument(
        "--template", type=Path, default=None,
        help="Markdown template file with !!table!! placeholder",
    )
    parser.add_argument(
        "--output", "-o", type=Path, default=None,
        help="Output file path (default: stdout)",
    )
    parser.add_argument(
        "--matrix", action="store_true",
        help="Include version matrix from show-matrix.sh --markdown",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print to stdout even if --output is set",
    )
    args = parser.parse_args()

    stack_base, version_dir = resolve_version_dir(args.stack_dir, args.version)

    # Render and parse
    template = render_cluster_class(version_dir)
    table = generate_table(template)

    # Generate version matrix if requested
    matrix = ""
    if args.matrix:
        script = Path(__file__).parent / "show-matrix.sh"
        result = subprocess.run(
            ["bash", str(script), str(stack_base), "--markdown"],
            capture_output=True, check=False,
        )
        if result.returncode == 0:
            matrix = result.stdout.decode("utf-8").strip()
        else:
            print(f"show-matrix.sh failed:\n{result.stderr.decode()}", file=sys.stderr)

    # Apply template if provided
    if args.template and args.template.exists():
        output = args.template.read_text(encoding="utf-8")
        output = output.replace("!!table!!", table)
        output = output.replace("!!matrix!!", matrix)
    else:
        output = table

    # Output
    if args.dry_run or args.output is None:
        print(output)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
        print(f"Written: {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
