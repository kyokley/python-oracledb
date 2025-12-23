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

    nix-oracle-db = {
      # url = "github:kyokley/nix-oracle-db";
      url = "git+file:///home/yokley/workspace/nix-oracle-db";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ODPI-C submodule (src/oracledb/impl/thick/odpi/src) as a flake input.
    # We fetch it directly and inject it into the build, so setuptools finds it.
    odpi = {
      url = "github:oracle/odpi";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    uv2nix,
    pyproject-nix,
    pyproject-build-systems,
    nix-oracle-db,
    odpi,
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
          # Ensure the ODPI-C submodule is present at the expected path for the build
          oracledb = prev.oracledb.overrideAttrs (old: {
            postPatch =
              (old.postPatch or "")
              + ''
                echo "Injecting ODPI-C sources into src/oracledb/impl/thick/odpi/src"
                mkdir -p src/oracledb/impl/thick/odpi
                # Replace any existing entry and link the ODPI-C 'src' directory
                rm -f src/oracledb/impl/thick/odpi/src
                ln -s ${odpi}/src src/oracledb/impl/thick/odpi/src

                rm -f src/oracledb/impl/thick/odpi/include
                ln -s ${odpi}/include src/oracledb/impl/thick/odpi/include

                rm -f src/oracledb/impl/thick/odpi/embed
                ln -s ${odpi}/embed src/oracledb/impl/thick/odpi/embed
              '';
          });
        };

        # 4. Construct the Final Python Package Set
        pythonSet = (pkgs.callPackage pyproject-nix.build.packages {inherit python;})
          .overrideScope (nixpkgs.lib.composeManyExtensions [
          pyproject-build-systems.overlays.default # For build tools
          uvLockedOverlay # Your locked dependencies
          myCustomOverrides # Your fixes (inject ODPI-C)
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
          src = ./.;
          nativeBuildInputs = [pkgs.makeWrapper];
          buildInputs = [appPythonEnv ]; # Runtime Python environment

          installPhase = ''
            mkdir -p $out/bin
            cp ./test_script.py $out/bin/test_script.py
            chmod +x $out/bin/test_script.py
            makeWrapper ${appPythonEnv}/bin/python $out/bin/test-db-script \
              --add-flags $out/bin/test_script.py
          '';
        };
        packages.test-suite = pkgs.stdenv.mkDerivation {
          pname = thisProjectAsNixPkg.pname;
          version = thisProjectAsNixPkg.version;
          src = ./.;
          nativeBuildInputs = [pkgs.makeWrapper];
          buildInputs = [appPythonEnv ]; # Runtime Python environment

          installPhase = ''
            mkdir -p $out/bin $out/lib
            cp -r ./tests $out/lib/tests
            makeWrapper ${appPythonEnv}/bin/python $out/bin/create_schema \
              --add-flags pytest \
              --add-flags $out/lib/tests/create_schema.py

            makeWrapper ${appPythonEnv}/bin/python $out/bin/pytest \
              --add-flags pytest

            makeWrapper ${appPythonEnv}/bin/python $out/bin/drop_schema \
              --add-flags pytest \
              --add-flags $out/lib/tests/drop_schema.py
          '';
        };
        # packages.${thisProjectAsNixPkg.pname} = self.packages.${system}.default;

        # # App for `nix run`
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/test-db-script";
          meta = {
            description = "Run the database test script using the project virtual environment";
          };
        };
        # apps.${thisProjectAsNixPkg.pname} = self.apps.${system}.default;

        checks = let
          hostAddress = "80.100.100.1";

          externalVMAddress = "80.100.100.2";
          internalVMAddress = "80.100.101.1";

          dbAddress = "80.100.101.2";

          defaultVmPort = 1022;
          defaultDbPort = 1521;
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
                  self.packages.${system}.test-suite
                ];

                services.openssh = {
                  enable = true;
                  settings = {
                    PermitRootLogin = "yes";
                    PermitEmptyPasswords = "yes";
                  };
                  ports = [defaultVmPort];
                };

                networking = {
                  firewall = {
                    enable = true;
                    allowedTCPPorts = [defaultVmPort];
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
                imports = [
                  # nix-oracle-db.nixosModules.oracle-database
                  nix-oracle-db.nixosModules.oracle-database
                ];

                # environment.etc."oratab" = {
                # text = ''
                #   free:/var/lib/oracle-database/oradata/free:N
                # '';
                # mode = "0666";
                # };

                services.oracle-database = {
                  enable = true;
                  passwordFile = ./password.txt;
                  # Explicitly use the package from the nix-oracle-db flake,
                  # avoiding reliance on pkgs having an overlay.
                  package = nix-oracle-db.packages.${system}.oracle-database;
                  openFirewall = true;
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
              db.wait_for_unit("oracle-database.target")
              vm.succeed("create_schema")
              vm.succeed("pytest")
              # vm.succeed("test-script")
            '';
          };
        };
      }
    );
}
