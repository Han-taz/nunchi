def bad(conn, table, user):
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute(f"SELECT * FROM {table}")
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute("SELECT * FROM %s" % table)
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute("SELECT * FROM {}".format(table))
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute("SELECT * FROM " + table)
    # ruleid: nunchi-formatted-sql-in-execute
    conn.executemany(f"INSERT INTO {table} VALUES (%s)", [(1,)])


def good(conn, user):
    # ok: nunchi-formatted-sql-in-execute
    conn.execute("SELECT * FROM t WHERE u = %s", (user,))
    # ok: nunchi-formatted-sql-in-execute
    conn.execute("SELECT 1")
