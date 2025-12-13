import oracledb
# import getpass


def main():
    un = "scott"                  # Sample database username
    cs = "localhost/orclpdb"      # Sample database connection string
    # cs = "localhost/freepdb1"   # For Oracle Database Free users
    # cs = "localhost/orclpdb1"   # Some databases may have this service
    # pw = getpass.getpass(f"Enter password for {un}@{cs}: ")
    pw = "password"

    with oracledb.connect(user=un, password=pw, dsn=cs) as connection:
        with connection.cursor() as cursor:
            sql = "select sysdate from dual"
            for r in cursor.execute(sql):
                print(r)
