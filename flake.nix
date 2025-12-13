{
  description = "Python driver for Oracle Database";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Core pyproject-nix ecosystem tools
    pyproject-nix.url = "github:pyproject-nix/pyproject.nix";
    uv2nix.url = "github:pyproject-nix/uv2nix";
    pyproject-build-systems.url = "github:pyproject-nix/build-system-pkgs";

    # Ensure consistent dependencies between these tools
    pyproject-nix.inputs.nixpkgs.follows = "nixpkgs";
    uv2nix.inputs.nixpkgs.follows = "nixpkgs";
    pyproject-build-systems.inputs.nixpkgs.follows = "nixpkgs";
    uv2nix.inputs.pyproject-nix.follows = "pyproject-nix";
    pyproject-build-systems.inputs.pyproject-nix.follows = "pyproject-nix";

    nix-oracle-db.url = "github:drupol/nix-oracle-db";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    uv2nix,
    pyproject-nix,
    pyproject-build-systems,
    nix-oracle-db,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};
        python = pkgs.python314; # Your desired Python version

        # 1. Load Project Workspace (parses pyproject.toml, uv.lock)
        workspace = uv2nix.lib.workspace.loadWorkspace {
          workspaceRoot = ./.; # Root of your flake/project
        };

        # 2. Generate Nix Overlay from uv.lock (via workspace)
        uvLockedOverlay = workspace.mkPyprojectOverlay {
          sourcePreference = "wheel"; # Or "sdist"
        };

        # 3. Placeholder for Your Custom Package Overrides
        myCustomOverrides = final: prev: {
          # e.g., some-package = prev.some-package.overridePythonAttrs (...); */
        };

        # 4. Construct the Final Python Package Set
        pythonSet = (pkgs.callPackage pyproject-nix.build.packages {inherit python;})
          .overrideScope (nixpkgs.lib.composeManyExtensions [
          pyproject-build-systems.overlays.default # For build tools
          uvLockedOverlay # Your locked dependencies
          myCustomOverrides # Your fixes
        ]);

        # --- This is where your project's metadata is accessed ---
        projectNameInToml = "oracledb"; # MUST match [project.name] in pyproject.toml!
        thisProjectAsNixPkg = pythonSet.${projectNameInToml};
        # ---

        # 5. Create the Python Runtime Environment
        appPythonEnv =
          pythonSet.mkVirtualEnv
          (thisProjectAsNixPkg.pname + "-env")
          workspace.deps.default; # Uses deps from pyproject.toml [project.dependencies]
      in {
        # Development Shell
        devShells.default = pkgs.mkShell {
          packages = [appPythonEnv pkgs.ruff pkgs.uv];
          shellHook = ''
            ${pkgs.figlet}/bin/figlet -f slant "python-oracledb" | ${pkgs.lolcat}/bin/lolcat
          '';
        };

        # # Nix Package for Your Application
        packages.default = pkgs.stdenv.mkDerivation {
          pname = thisProjectAsNixPkg.pname;
          version = thisProjectAsNixPkg.version;
          src = ./.; # Source of your main script

          nativeBuildInputs = [ pkgs.makeWrapper ];
          buildInputs = [ appPythonEnv ]; # Runtime Python environment

          installPhase = ''
            mkdir -p $out/bin
            cp ./test_script.py $out/bin/test_script.py
            chmod +x $out/bin/test_script.py
            makeWrapper ${appPythonEnv}/bin/python $out/bin/test-db-script \
              --add-flags $out/bin/test_script.py
          '';
        };
        # packages.${thisProjectAsNixPkg.pname} = self.packages.${system}.default;

        # # App for `nix run`
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/${thisProjectAsNixPkg.pname}";
        };
        # apps.${thisProjectAsNixPkg.pname} = self.apps.${system}.default;

        checks = let
          hostAddress = "80.100.100.1";

          externalVMAddress = "80.100.100.2";
          internalVMAddress = "80.100.101.1";

          dbAddress = "80.100.101.2";

          default-vm-port = 1022;
        in {
          moduleTest = pkgs.testers.runNixOSTest {
            name = "moduleTest";
            nodes = {
              host = {
                environment.systemPackages = [
                  self.packages.${system}.default
                ];

                virtualisation.vlans = [1];
                networking.interfaces.eth1.ipv4.addresses = [
                  {
                    address = hostAddress;
                    prefixLength = 24;
                  }
                ];
              };

              vm = {pkgs, ...}: {
                environment.systemPackages = [
                  self.packages.${system}.default
                ];

                services.openssh = {
                  enable = true;
                  settings = {
                    PermitRootLogin = "yes";
                    PermitEmptyPasswords = "yes";
                  };
                  ports = [default-vm-port];
                };

                networking = {
                  firewall = {
                    enable = true;
                    allowedTCPPorts = [default-vm-port];
                  };
                  nat = {
                    enable = true;
                    internalInterfaces = ["eth1"];
                    externalInterface = "eth2";
                  };
                };

                users.users.root.hashedPassword = ""; # "" means passwordless login
                security.pam.services.sshd.allowNullPassword = true;
                virtualisation.vlans = [1 2];
                networking.interfaces = {
                  eth1.ipv4.addresses = [
                    {
                      address = internalVMAddress;
                      prefixLength = 24;
                    }
                  ];
                  eth2.ipv4.addresses = [
                    {
                      address = externalVMAddress;
                      prefixLength = 24;
                    }
                  ];
                };
              };

              db = {
                imports = [nix-oracle-db.nixosModules.oracle-database-container];

                services.oracle-database-container = {
                  enable = true;
                  openFirewall = true;
                  volumeName = "oracledb";
                  passwordFile = builtins.toFile "passwordFile" "password";
                };
                virtualisation.vlans = [2];
                networking.interfaces.eth1.ipv4.addresses = [
                  {
                    address = dbAddress;
                    prefixLength = 24;
                  }
                ];
              };
            };

            testScript = ''
              start_all()
              db.wait_for_unit("oracle-database-container.target")
              vm.succeed("test-script")
            '';
          };
        };
      }
    );
}
