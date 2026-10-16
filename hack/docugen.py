#!/usr/bin/env python3

"""
Generate markdown documentation from ClusterClass variable definitions.

Renders the cluster-class Helm template, parses the topology variables
(openAPIV3Schema), and outputs a markdown table of all configurable options.

Usage:
    ./hack/docugen.py <stack-dir>
    ./hack/docugen.py <stack-dir> --output docs/configuration.md
    ./hack/docugen.py <stack-dir> --template hack/config-template.md
    ./hack/docugen.py <stack-dir> --dry-run
"""

import argparse
import subprocess
import sys
from pathlib import Path

import yaml


def generate_row(columns: list) -> str:
    """Generate a markdown table row from a list of column values."""
    return "|" + "|".join(str(c) for c in columns) + "|"


def parse_variable(var: dict) -> list:
    """Parse a simple variable (string, boolean, integer, array) into table columns."""
    name = var["name"]
    required = var["required"]
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
        "stack_dir", type=Path,
        help="Path to the cluster stack directory",
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
        "--dry-run", action="store_true",
        help="Print to stdout even if --output is set",
    )
    args = parser.parse_args()

    # Render and parse
    template = render_cluster_class(args.stack_dir)
    table = generate_table(template)

    # Apply template if provided
    if args.template and args.template.exists():
        output = args.template.read_text().replace("!!table!!", table)
    else:
        output = table

    # Output
    if args.dry_run or args.output is None:
        print(output)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output)
        print(f"Written: {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
