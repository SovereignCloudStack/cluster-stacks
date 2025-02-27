#!/usr/bin/env python3

"""
Generate version-specific hierarchy of the cluster-stacks repo.

This is a helper script to generate a version-specific folder structure
of the base cluster-stacks implementation. The source directory is in
`cluster-stacks/providers/openstack/scs` and supported versions are maintained
in a file `versions.yaml` within the source directory. The source directory is a 
valid variant of this repo, pinned to the smallest supported version.
"""


import argparse
import logging
import shutil
import subprocess
import sys
from pathlib import Path, PosixPath

import yaml

BASE_PATH = Path(__file__).parent.parent
SOURCE_PATH = BASE_PATH.joinpath("providers", "openstack", "scs")
DEFAULT_TARGET_PATH = BASE_PATH.joinpath("providers", "openstack", "out")

logger = logging.getLogger(__name__)


def load_supported_versions() -> list:
    """
    Read supported versions from file for output or further usage inside this script.

        Parameters:
            None

        Returns:
            List of supported versions
    """
    logger.info("Loading supported versions.")
    version_file = SOURCE_PATH.joinpath("versions.yaml")
    with open(version_file, encoding="utf-8") as stream:
        try:
            result = yaml.safe_load(stream)
        except yaml.YAMLError as exc:
            print(exc)

    return result


def get_dash_version(version: str) -> str:
    """
    Helper function to convert version from dotted to separated by hyphen. (1.27.14 -> 1-27)
        Parameters:
            version (string): String containing the full semver version.

        Returns:
            String with shortened version separated by a hypgen.
    """
    return "-".join(version.split(".")[0:2])


def create_output_dir(version: str) -> PosixPath:
    """
    Prepare output directory by creating it and copying the source files over.
    This overwrites files existing inside the output directory, as those
    should not be edited manually.

        Parameters:
            version (string): Semver version string as read from the supported versions list.

        Returns:
            PosixPath object of the created directory.
    """
    out = get_dash_version(version)
    out_dir = DEFAULT_TARGET_PATH.joinpath(out)

    logger.info("Creating output directory at %s", out_dir)

    # TODO: how to handle FileExistsError?
    # as the output is being generated, it *should* be safe to overwrite
    if out_dir.exists():
        shutil.rmtree(str(out_dir))

    # Copy whole tree from src dir and remove "versions.yaml" file
    shutil.copytree(SOURCE_PATH, out_dir)
    out_dir.joinpath("versions.yaml").unlink()
    out_dir.joinpath("cluster-addon", "Chart.lock").unlink()
    shutil.rmtree(str(out_dir.joinpath("cluster-addon", "charts")))

    return out_dir


def readfile(path: PosixPath):
    """
    Helper function to read yaml configuration files.

        Parameters:
            path (PosixPath): pathlib object of the file to open.

        Returns:
            Content of the yaml configuration file.
    """
    # TODO: yaml.safe_load either returns a list or dict,
    # depending on the structure of the yaml file. This can be improved / refactored.
    with open(path, encoding="utf-8") as stream:
        try:
            content = yaml.safe_load(stream)
        except yaml.YAMLError as exc:
            print(exc)

    return content


def writefile(path: PosixPath, content):
    """
    Helper function to write content to a yaml configuration file.

        Parameters:
            path (PosixPath): pathlib object of the target file path.
            content: yaml data to be written. This can either be of type list or dict.

        Returns:
            None
    """
    with open(path, "w", encoding="utf-8") as stream:
        yaml.safe_dump(content, stream)


def update_cluster_addon(
    target: PosixPath, build: bool, build_verbose: bool, **versions
):
    """
    Update relevant files inside the cluster-stacks/<path>/cluster-addon subdirectory

        Parameters:
            target (PosixPath): pathlib object of the relevant file.
            build (boolean): Toggle to control if helm dependencies should be build,
            build_verbose (boolean): Toggle to control if build output should be printed.
            versions (kwargs): Dictionary of version information.

        Returns:
            None
    """
    logger.info("Updating %s", target)
    content = readfile(target)

    for dep in content["dependencies"]:
        if dep["name"] == "openstack-cinder-csi":
            dep["version"] = versions["cinder_csi"]

        if dep["name"] == "openstack-cloud-controller-manager":
            dep["version"] = versions["occm"]

    content["name"] = (
        f"openstack-scs-{get_dash_version(versions['kubernetes'])}-cluster-addon"
    )

    writefile(target, content)

    if build:
        logger.info("Building helm dependencies")
        cmd = ["helm", "dependency", "build"]
        subprocess.run(
            cmd,
            cwd=str(target).replace("Chart.yaml", ""),
            capture_output=build_verbose,
            check=False,
        )


def update_csctl_conf(target: PosixPath, **versions):
    """
    Function to update csctl configuration file.

        Parameters:
            target (PosixPath): pathlib object of the relevant file.
            versions (kwargs): Dictionary of version information.

        Returns:
            None
    """
    logger.info("Updating %s", target)
    content = readfile(target)

    content["config"]["kubernetesVersion"] = f"v{versions['kubernetes']}"

    writefile(target, content)


def update_cluster_class(target: PosixPath, **kwargs):
    """
    Update relevant files inside the cluster-stacks/<path>/cluster-class subdirectory.

        Parameters:
            target (PosixPath): pathlib object of the relevant file.
            versions (kwargs): Dictionary of version information.

        Returns:
            None
    """
    chart_file = target.joinpath("Chart.yaml")
    values_file = target.joinpath("values.yaml")

    logger.info("Updating %s", chart_file)
    content = readfile(chart_file)
    version = get_dash_version(kwargs["kubernetes"])
    content["name"] = f"openstack-scs-{version}-cluster-class"

    writefile(chart_file, content)

    logger.info("Updating %s", values_file)
    content = readfile(values_file)

    content["images"]["controlPlane"][
        "name"
    ] = f"ubuntu-capi-image-v{kwargs['kubernetes']}"
    content["images"]["worker"]["name"] = f"ubuntu-capi-image-v{kwargs['kubernetes']}"

    writefile(values_file, content)


def update_node_images(target: PosixPath, **kwargs):
    """
    Update relevant files inside the cluster-stacks/<path>/node-images subdirectory.

        Parameters:
            target (PosixPath): pathlib object of the relevant file.
            versions (kwargs): Dictionary of version information.

        Returns:
            None
    """
    logger.info("Updating %s", target)
    content = readfile(target)

    # TODO: can this magic URL be 'removed'?
    # pylint: disable=locally-disabled, line-too-long
    url = f'https://swift.services.a.regiocloud.tech/swift/v1/AUTH_b182637428444b9aa302bb8d5a5a418c/openstack-k8s-capi-images/ubuntu-2204-kube-v{kwargs["kubernetes"][0:4]}/ubuntu-2204-kube-v{kwargs["kubernetes"]}.qcow2'
    content["openStackNodeImages"][0]["url"] = url

    content["openStackNodeImages"][0]["createOpts"][
        "name"
    ] = f"ubuntu-capi-image-v{kwargs['kubernetes']}"

    writefile(target, content)


if __name__ == "__main__":
    LOGFORMAT = "%(asctime)s - %(levelname)s: %(message)s"
    logging.basicConfig(level=logging.INFO, encoding="utf-8", format=LOGFORMAT)
    # Initialize arg parser
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-t",
        "--target-version",
        type=str,
        help="Generate files for version specified like 1.XX. See '-l' to list supported versions.",
    )
    parser.add_argument(
        "-l", "--list", action="store_true", help="List supported versions and exit."
    )
    parser.add_argument("--build", action="store_true", help="Build helm dependencies.")
    parser.add_argument(
        "--build-verbose", action="store_false", help="Show output of helm build"
    )
    args = parser.parse_args()

    # Load supported target versions
    sup_versions = load_supported_versions()

    if args.list:
        print("Supported Kubernetes Versions:")
        for v in sup_versions:
            print(f"{'.'.join(v['kubernetes'].split('.')[0:2])}")
        print("Usage: generate_version.py --target-version VERSION")
        sys.exit()

    # filter versions to generate
    if args.target_version:
        target_versions = [
            v for v in sup_versions if v["kubernetes"].startswith(args.target_version)
        ]
    else:
        target_versions = sup_versions

    for tv in target_versions:
        output_dir = create_output_dir(tv["kubernetes"])
        update_cluster_addon(
            output_dir.joinpath("cluster-addon", "Chart.yaml"),
            args.build,
            args.build_verbose,
            **tv,
        )
        update_csctl_conf(output_dir.joinpath("csctl.yaml"), **tv)
        update_cluster_class(output_dir.joinpath("cluster-class"), **tv)
        update_node_images(output_dir.joinpath("node-images", "config.yaml"), **tv)
