{
  description = "Description for the project";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    devshell.url = "github:numtide/devshell";
    nix-oracle-db.url = "github:kyokley/nix-oracle-db/gvenzl";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        # To import an internal flake module: ./other.nix
        # To import an external flake module:
        #   1. Add foo to inputs
        #   2. Add foo as a parameter to the outputs function
        #   3. Add here: foo.flakeModule
        inputs.devshell.flakeModule
      ];
      systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin"];
      perSystem = {
        config,
        self',
        inputs',
        pkgs,
        system,
        ...
      }: {
        # Per-system attributes can be defined here. The self' and inputs'
        # module parameters provide easy access to attributes of the same
        # system.

        devshells.default = {
          env = [
            {
              name = "VIRTUAL_ENV";
              value = "venv";
            }
            {
              name = "PATH";
              prefix = "$VIRTUAL_ENV/bin";
            }
            {
              name = "LD_LIBRARY_PATH";
              prefix = "${pkgs.stdenv.cc.cc.lib}/lib";
            }
            {
              name = "PYO_TEST_MAIN_USER";
              value = "main_user";
            }
            {
              name = "PYO_TEST_MAIN_PASSWORD";
              value = "password";
            }
          ];
          packages = [
            pkgs.gcc
          ];
        };

        # Equivalent to  inputs'.nixpkgs.legacyPackages.hello;
        # packages.default = pkgs.hello;

        checks = {
          tests = pkgs.testers.runNixOSTest {
            name = "tests";
            nodes = {
              db = {
                imports = [
                  # To import an internal flake module: ./test.nix
                  # To import an external flake module:
                  #   1. Add foo to inputs
                  #   2. Add foo as a parameter to the outputs function
                  #   3. Add here: foo.flakeModule
                  inputs.nix-oracle-db.nixosModules.oracle-database-container
                ];

                services.oracle-database-container = {
                  enable = true;
                  openFirewall = true;
                  passwordFile = toString (builtins.toFile "password.txt" ''
                    password
                  '');
                  initScript = builtins.toFile "01_create.sql" ''
                    ALTER SESSION SET CONTAINER=FREEPDB1;
                    CREATE USER TEST IDENTIFIED BY test QUOTA UNLIMITED ON USERS;
                    GRANT CONNECT, RESOURCE TO TEST;

                    CREATE TABLE student (
                        last_name       VARCHAR2(15) NOT NULL,
                        first_name      VARCHAR2(15) NOT NULL,
                        id              NUMBER(6) PRIMARY KEY
                    );
                    INSERT INTO students (last_name, first_name, id)
                    VALUES ('Doe', 'John', 1001);

                  '';
                };
              };
            };
            testScript = ''
              start_all()
              db.wait_for_unit("oracle-database-container.target")
            '';
          };
        };
      };
      flake = {
        # The usual flake attributes can be defined here, including system-
        # agnostic ones like nixosModule and system-enumerating ones, although
        # those are more easily expressed in perSystem.
      };
    };
}
