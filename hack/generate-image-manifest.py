#!/usr/bin/env python3

"""
Generate OpenStack Image manifests for Kubernetes CAPI images.

This script reads versions.yaml from a cluster stack directory and generates
OpenStack Image CRD manifests for each Kubernetes version. The generated
manifests can be used to upload CAPI images to OpenStack via the Image CRD.

The script uses the pattern from /data/image.yaml as a template, with hardware
properties set to: diskBus=scsi, scsiModel=virtio-scsi for optimal performance.

Image URL pattern:
  https://nbg1.your-objectstorage.com/osism/openstack-k8s-capi-images/
  ubuntu-2404-kube-v{MAJOR.MINOR}/ubuntu-2404-kube-v{FULL_VERSION}.qcow2

Checksum pattern:
  {IMAGE_URL}.CHECKSUM (contains: sha256sum filename)

Usage:
  # Generate for all versions
  ./hack/generate-image-manifest.py

  # Generate for specific version
  ./hack/generate-image-manifest.py --version 1.35.0

  # Generate to directory
  ./hack/generate-image-manifest.py --output-dir manifests/images/

  # Skip checksum validation (for images not yet available)
  ./hack/generate-image-manifest.py --version 1.35.0 --skip-checksum
"""

import argparse
import logging
import os
import sys
from pathlib import Path
from typing import Optional, Dict, Any

import yaml
import requests

# Base directory
BASE_PATH = Path(__file__).parent.parent

# Default values
DEFAULT_PROVIDER = "openstack"
DEFAULT_STACK = "scs2"
DEFAULT_BASE_URL = "https://nbg1.your-objectstorage.com/osism/openstack-k8s-capi-images"
DEFAULT_CLOUD_NAME = "openstack"
DEFAULT_SECRET_NAME = "openstack"

logger = logging.getLogger(__name__)


def get_dash_version(version: str) -> str:
    """
    Convert version from dotted to dash-separated.
    
    Examples:
        1.35.0 -> 1.35
        1.34.3 -> 1.34
    """
    return ".".join(version.split(".")[0:2])


def load_versions(provider: str, stack: str) -> list:
    """
    Load supported Kubernetes versions from versions.yaml.
    
    Args:
        provider: Provider name (e.g., 'openstack')
        stack: Stack name (e.g., 'scs2')
        
    Returns:
        List of version dictionaries
    """
    versions_file = BASE_PATH / "providers" / provider / stack / "versions.yaml"
    
    if not versions_file.exists():
        logger.error(f"versions.yaml not found: {versions_file}")
        sys.exit(1)
    
    logger.info(f"Loading versions from {versions_file}")
    
    with open(versions_file, encoding="utf-8") as f:
        versions = yaml.safe_load(f)
    
    return versions


def fetch_checksum(url: str, timeout: int = 30) -> Optional[str]:
    """
    Fetch SHA256 checksum from URL.CHECKSUM file.
    
    The .CHECKSUM file format is typically:
        <sha256sum> <filename>
    
    Args:
        url: Base image URL (without .CHECKSUM)
        timeout: Request timeout in seconds
        
    Returns:
        SHA256 checksum string, or None if fetch fails
    """
    checksum_url = f"{url}.CHECKSUM"
    
    try:
        logger.info(f"Fetching checksum from {checksum_url}")
        response = requests.get(checksum_url, timeout=timeout)
        response.raise_for_status()
        
        # Parse checksum line: "abc123... filename.qcow2"
        checksum_line = response.text.strip()
        checksum = checksum_line.split()[0]
        
        logger.info(f"Found checksum: {checksum[:16]}...")
        return checksum
        
    except requests.exceptions.RequestException as e:
        logger.error(f"Failed to fetch checksum from {checksum_url}: {e}")
        return None


def generate_image_url(base_url: str, version: str) -> str:
    """
    Generate image URL for a Kubernetes version.
    
    Pattern: {base_url}/ubuntu-2404-kube-v{MAJOR.MINOR}/ubuntu-2404-kube-v{FULL}.qcow2
    
    Args:
        base_url: Base URL (without trailing slash)
        version: Full K8s version (e.g., "1.35.0")
        
    Returns:
        Complete image URL
    """
    major_minor = get_dash_version(version)
    return f"{base_url}/ubuntu-2404-kube-v{major_minor}/ubuntu-2404-kube-v{version}.qcow2"


def generate_manifest(
    version: str,
    base_url: str,
    cloud_name: str,
    secret_name: str,
    skip_checksum: bool = False
) -> Dict[str, Any]:
    """
    Generate Image CRD manifest for a Kubernetes version.
    
    Args:
        version: Full K8s version (e.g., "1.35.0")
        base_url: Base URL for images
        cloud_name: CloudCredentialsRef cloud name
        secret_name: CloudCredentialsRef secret name
        skip_checksum: Skip checksum fetching
        
    Returns:
        Dictionary representing the Image manifest
    """
    image_url = generate_image_url(base_url, version)
    
    # Fetch checksum unless skipped
    checksum = None
    if not skip_checksum:
        checksum = fetch_checksum(image_url)
        if checksum is None:
            logger.error(f"Cannot fetch checksum for version {version}")
            logger.error("Use --skip-checksum to generate manifest without hash validation")
            return None
    
    # Build manifest
    manifest = {
        "apiVersion": "openstack.k-orc.cloud/v1alpha1",
        "kind": "Image",
        "metadata": {
            "name": f"ubuntu-capi-image-v{version}"
        },
        "spec": {
            "cloudCredentialsRef": {
                "cloudName": cloud_name,
                "secretName": secret_name
            },
            "managementPolicy": "managed",
            "resource": {
                "visibility": "private",
                "properties": {
                    "hardware": {
                        "diskBus": "scsi",
                        "scsiModel": "virtio-scsi",
                        "vifModel": "virtio",
                        "qemuGuestAgent": True,
                        "rngModel": "virtio"
                    },
                    "architecture": "x86_64",
                    "minDiskGB": 20,
                    "minMemoryMB": 2048,
                    "operatingSystem": {
                        "distro": "ubuntu",
                        "version": "24.04"
                    }
                },
                "content": {
                    "diskFormat": "qcow2",
                    "download": {
                        "url": image_url
                    }
                }
            }
        }
    }
    
    # Add hash only if checksum was fetched
    if checksum:
        manifest["spec"]["resource"]["content"]["download"]["hash"] = {
            "algorithm": "sha256",
            "value": checksum
        }
    
    return manifest


def write_manifest(manifest: Dict[str, Any], output_path: Optional[Path] = None):
    """
    Write manifest to file or stdout.
    
    Args:
        manifest: Manifest dictionary
        output_path: Output file path, or None for stdout
    """
    yaml_str = yaml.dump(manifest, default_flow_style=False, sort_keys=False)
    
    if output_path:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write("---\n")
            f.write(yaml_str)
        logger.info(f"Written manifest to {output_path}")
    else:
        print("---")
        print(yaml_str, end="")


if __name__ == "__main__":
    # Setup logging
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s: %(message)s"
    )
    
    # Parse arguments
    parser = argparse.ArgumentParser(
        description="Generate OpenStack Image manifests for Kubernetes CAPI images"
    )
    parser.add_argument(
        "--provider",
        type=str,
        default=os.environ.get("PROVIDER", DEFAULT_PROVIDER),
        help=f"Provider name (default: {DEFAULT_PROVIDER})"
    )
    parser.add_argument(
        "--stack",
        type=str,
        default=os.environ.get("CLUSTER_STACK", os.environ.get("STACK", DEFAULT_STACK)),
        help=f"Stack name (default: {DEFAULT_STACK})"
    )
    parser.add_argument(
        "--version",
        type=str,
        help="Generate for specific K8s version (e.g., 1.35.0)"
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Output directory for manifests (default: stdout)"
    )
    parser.add_argument(
        "--base-url",
        type=str,
        default=DEFAULT_BASE_URL,
        help=f"Base URL for images (default: {DEFAULT_BASE_URL})"
    )
    parser.add_argument(
        "--cloud-name",
        type=str,
        default=DEFAULT_CLOUD_NAME,
        help=f"CloudCredentialsRef cloud name (default: {DEFAULT_CLOUD_NAME})"
    )
    parser.add_argument(
        "--secret-name",
        type=str,
        default=DEFAULT_SECRET_NAME,
        help=f"CloudCredentialsRef secret name (default: {DEFAULT_SECRET_NAME})"
    )
    parser.add_argument(
        "--skip-checksum",
        action="store_true",
        help="Skip checksum fetching (omit hash field entirely)"
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List available versions and exit"
    )
    
    args = parser.parse_args()
    
    # Load versions
    versions = load_versions(args.provider, args.stack)
    
    if args.list:
        print(f"Available Kubernetes versions in {args.provider}/{args.stack}:")
        for v in versions:
            print(f"  {v['kubernetes']}")
        sys.exit(0)
    
    # Filter versions if specific version requested
    if args.version:
        versions = [v for v in versions if v["kubernetes"] == args.version]
        if not versions:
            logger.error(f"Version {args.version} not found in versions.yaml")
            sys.exit(1)
    
    # Generate manifests
    success_count = 0
    fail_count = 0
    
    for v in versions:
        k8s_version = v["kubernetes"]
        logger.info(f"Generating manifest for Kubernetes {k8s_version}")
        
        manifest = generate_manifest(
            version=k8s_version,
            base_url=args.base_url,
            cloud_name=args.cloud_name,
            secret_name=args.secret_name,
            skip_checksum=args.skip_checksum
        )
        
        if manifest is None:
            fail_count += 1
            continue
        
        # Determine output path
        output_path = None
        if args.output_dir:
            filename = f"ubuntu-capi-image-v{k8s_version}.yaml"
            output_path = args.output_dir / filename
        
        write_manifest(manifest, output_path)
        success_count += 1
    
    # Summary
    if args.output_dir:
        logger.info(f"Generated {success_count} manifest(s) in {args.output_dir}")
    
    if fail_count > 0:
        logger.error(f"Failed to generate {fail_count} manifest(s)")
        sys.exit(1)
