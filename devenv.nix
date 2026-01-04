{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: {
  # https://devenv.sh/basics/
  env = {
    GREET = "python-oracledb";
    ORACLE_PASSWORD = "password";
    ORACLE_LISTEN_ADDRESS = "127.0.0.1";
    ORACLE_LISTEN_PORT = 1521;
    ORACLE_CONTAINER_NAME = "oracledb";
    ORACLE_APP_USER = "my_user";
    ORACLE_APP_USER_PASSWORD = "password";
    USE_HOST_NET = 1;
  };

  # https://devenv.sh/packages/
  packages = [pkgs.docker];

  # https://devenv.sh/languages/
  languages = {
    python = {
      enable = true;
      version = "3.13";
      uv.enable = true;
    };
  };

  # https://devenv.sh/processes/
  # processes.dev.exec = "${lib.getExe pkgs.watchexec} -n -- ls -la";

  # https://devenv.sh/services/
  # services.postgres.enable = true;

  # https://devenv.sh/scripts/
  scripts = {
    hello.exec = ''
      echo $GREET
    '';
    up.exec = let
      initScriptFile = builtins.toFile "01_create.sql" ''
        ALTER SESSION SET current_schema = ${config.env.ORACLE_APP_USER};

        CREATE TABLE student (
            last_name       VARCHAR2(15) NOT NULL,
            first_name      VARCHAR2(15) NOT NULL,
            id              NUMBER(6) PRIMARY KEY
        );
        INSERT INTO student (last_name, first_name, id)
        VALUES ('Doe', 'John', 1001);
        SELECT * FROM student;
      '';
    in ''
      set -x
      : ''${USE_HOST_NET:=0}
      if [ $USE_HOST_NET -eq 1 ]
      then
        DOCKER_NET_ARGS="--net=host"
      else
        DOCKER_NET_ARGS="-p ${config.env.ORACLE_LISTEN_ADDRESS}:${toString config.env.ORACLE_LISTEN_PORT}:1521"
      fi

      docker run \
        --rm \
        -d \
        -t \
        --name ${config.env.ORACLE_CONTAINER_NAME} \
        -v ${toString initScriptFile}:/container-entrypoint-initdb.d/init.sql \
        ''${DOCKER_NET_ARGS} \
        -e ORACLE_PASSWORD="${config.env.ORACLE_PASSWORD}" \
        -e APP_USER="${config.env.ORACLE_APP_USER}" \
        -e APP_USER_PASSWORD="${config.env.ORACLE_APP_USER_PASSWORD}" \
        gvenzl/oracle-free

      logs
    '';
    logs.exec = ''
      docker logs --follow ${config.env.ORACLE_CONTAINER_NAME}
    '';
    down.exec = ''
      docker stop ${config.env.ORACLE_CONTAINER_NAME}
    '';
  };

  # https://devenv.sh/basics/
  enterShell = ''
    hello         # Run scripts directly
  '';

  # https://devenv.sh/tasks/
  # tasks = {
  #   "myproj:setup".exec = "mytool build";
  #   "devenv:enterShell".after = [ "myproj:setup" ];
  # };

  # https://devenv.sh/tests/
  enterTest = ''
    echo "Running tests"
    echo "Done"
  '';

  # https://devenv.sh/git-hooks/
  # git-hooks.hooks.shellcheck.enable = true;

  # See full reference at https://devenv.sh/reference/options/
}
