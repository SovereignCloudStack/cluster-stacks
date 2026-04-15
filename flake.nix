{
  description = "Cluster Stacks - Build tools for SCS Kubernetes cluster stacks";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          name = "cluster-stacks-dev";

          buildInputs = with pkgs; [
            # Core tools
            bash
            git
            curl

            # Container tools
            docker
            podman

            # Kubernetes tools
            kubectl
            kubernetes-helm
            kind
            kustomize

            # Build tools
            just
            python3
            python3Packages.pyyaml
            jq
            yq-go

            # OCI/Registry tools
            oras
          ];

          shellHook = ''
            echo "Cluster Stacks development environment"
            echo ""
            echo "Available tools:"
            echo "  just         - Run 'just --list' to see available commands"
            echo "  helm         - Kubernetes package manager"
            echo "  kubectl      - Kubernetes CLI"
            echo "  kind         - Local Kubernetes clusters"
            echo "  yq           - YAML processor"
            echo "  oras         - OCI registry client"
            echo "  python3      - With PyYAML"
            echo ""

            # Generate shell completions into a cache directory
            comp_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/cluster-stacks/completions"
            mkdir -p "$comp_dir"

            user_shell=$(getent passwd "$(whoami)" 2>/dev/null | cut -d: -f7)
            shell_name=$(basename "''${user_shell:-bash}")

            # Regenerate completions if the directory is empty or tools were updated
            if [ ! -f "$comp_dir/.$shell_name-generated" ]; then
              kubectl completion "$shell_name" > "$comp_dir/_kubectl" 2>/dev/null || true
              helm completion "$shell_name" > "$comp_dir/_helm" 2>/dev/null || true
              just --completions "$shell_name" > "$comp_dir/_just" 2>/dev/null || true
              kind completion "$shell_name" > "$comp_dir/_kind" 2>/dev/null || true
              oras completion "$shell_name" > "$comp_dir/_oras" 2>/dev/null || true
              touch "$comp_dir/.$shell_name-generated"
            fi

            # Make completions available
            export FPATH="$comp_dir:$FPATH"

            # Start user's preferred shell instead of bash.
            # nix develop always drops into bash; this detects the user's
            # real login shell from /etc/passwd and exec's into it.
            if [ -n "$user_shell" ] && [ "$shell_name" != "bash" ] && [ -x "$user_shell" ]; then
              exec "$user_shell"
            fi
          '';
        };
      }
    );
}
