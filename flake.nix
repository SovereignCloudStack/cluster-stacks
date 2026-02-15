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
            wget

            # Container tools
            docker
            podman

            # Kubernetes tools
            kubectl
            kubernetes-helm
            kind
            kustomize

            # Build tools
            go-task
            python3
            python3Packages.pyyaml
            python3Packages.requests
            jq
            yq-go

            # OCI/Registry tools
            oras
            
            # Optional but useful
            gnumake
            just
          ];

          shellHook = ''
            echo "🚀 Cluster Stacks development environment"
            echo ""
            echo "Available tools:"
            echo "  - task (go-task): Run 'task --list' to see available commands"
            echo "  - helm: Kubernetes package manager"
            echo "  - kubectl: Kubernetes CLI"
            echo "  - kind: Local Kubernetes clusters"
            echo "  - yq: YAML processor"
            echo "  - oras: OCI registry client"
            echo "  - python3: With PyYAML and requests"
            echo ""
            echo "📝 Configuration:"
            echo "  1. Copy task.env.example to task.env"
            echo "  2. Edit task.env with your settings"
            echo "  3. Run: task --list"
            echo ""
            
            # Source task.env if it exists
            if [ -f task.env ]; then
              export $(grep -v '^#' task.env | xargs)
              echo "✅ Loaded task.env"
            else
              echo "⚠️  task.env not found. Copy task.env.example to get started."
            fi
            
            # Set up PATH for local tools
            export PATH="$PWD/bin:$PATH"
          '';
        };
      }
    );
}
