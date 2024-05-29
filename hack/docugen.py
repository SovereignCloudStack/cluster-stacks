#!/usr/bin/env python3

"""
Generate markdown table from cluster-class variable definitions.

This script temporarily renders the helm template of the cluster-class.
Parses the `Cluster.spec.topology.variables` definitions and
generates a markdown table for documentation purposes.
"""


import subprocess
from pathlib import Path

import yaml

BASE_PATH = Path(__file__).parent.parent
TEMPLATE_PATH = BASE_PATH.joinpath(
    "providers", "openstack", "scs", "1-27", "cluster-class"
)


def generate_row(content: list):
    """Generate string of markdown table row."""
    row_tmpl = "|{content}|"
    row_str = "|".join(content)

    return row_tmpl.format(content=row_str)


def parse_variable(tmpl: dict) -> list:
    """
    Parse schema of simple cluster-stack variable type. (String, Boolean, Integer, Array)

        Parameters:
            tmpl (dict): Dictionary of variable schema,
                         parsed from cluster-class.yaml via yaml.safe_load().

        Returns: List of variable schema properties.
                 Each entry represents a column in the final markdown table row.
    """
    var_name = tmpl["name"]
    var_required = tmpl["required"]
    var_schema = tmpl["schema"]["openAPIV3Schema"]

    var_type = var_schema["type"]
    var_default = var_schema.get("default", "")
    var_example = var_schema.get("example", "")
    var_desc = var_schema.get("description", "TODO")

    row = []
    row.append(f"`{var_name}`")
    row.append(var_type)

    # Make sure that example and default values are quoted in the table
    if var_type == "string":
        row.append(f'"{var_default}"')
        row.append(f'"{var_example}"')

    # Cast any non-string type example / default to string
    if var_type in ["array", "integer", "boolean"]:
        row.append(str(var_default))
        row.append(str(var_example))

    row.append(var_desc.replace("\n", "<br>"))
    row.append(str(var_required))  # Convert boolean variable to string

    return row


def parse_object(tmpl: dict) -> list:
    """
    Parse cluster-stack variable schema of type object.
    Separated due to nesting in YAML format.
        Parameters:
            tmpl (dict): Dictionary of object schema,
                         parsed from cluster-class.yaml via yaml.safe_load().

        Returns:
            List of object properties.
            Each entry represents a row in the final markdown table as a list,
            consisting of the rows column values.
    """
    var_name = tmpl["name"]
    props = tmpl["schema"]["openAPIV3Schema"]["properties"]

    object_list = []
    for prop in props:
        row = []
        row.append(f"`{var_name}.{prop}`")
        row.append(props[prop]["type"])
        row.append(props[prop].get("default", ""))
        row.append(props[prop].get("example", ""))
        row.append(props[prop].get("description", "TODO"))
        # append dummy row for required field
        row.append("")

        object_list.append(row)
    return object_list


if __name__ == "__main__":
    cmd = [
        "helm",
        "template",
        "docugen",
        TEMPLATE_PATH,
        "-s",
        "templates/cluster-class.yaml",
    ]

    cmdout = subprocess.run(cmd, capture_output=True, check=False)
    rendered_template = cmdout.stdout.decode("utf-8")

    template = yaml.safe_load(rendered_template)

    result_table = []
    result_table.append("|Name|Type|Default|Example|Description|Required|")
    result_table.append("|----|----|-------|-------|-----------|--------|")

    for var in template["spec"]["variables"]:
        if var["schema"]["openAPIV3Schema"]["type"] in ["object"]:
            parsed = parse_object(var)
            for object_property in parsed:
                result_table.append(generate_row(object_property))
        else:
            parsed = parse_variable(var)
            result_table.append(generate_row(parsed))

    print("\n".join(result_table))
