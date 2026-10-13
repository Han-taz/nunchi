# Every case from the earlier single-pattern rule is kept here unchanged.
def inline_formats(conn, table, user):
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute(f"SELECT * FROM {table}")
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute("SELECT * FROM %s" % table)
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute("SELECT * FROM {}".format(table))
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute("SELECT * FROM {t}".format(t=table))
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute("SELECT * FROM " + table)
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute(table + " WHERE x = 1")
    # ruleid: nunchi-formatted-sql-in-execute
    conn.executemany(f"INSERT INTO {table} VALUES (%s)", [(1,)])
    # ruleid: nunchi-formatted-sql-in-execute
    conn.executemany("INSERT INTO " + table + " VALUES (%s)", [(1,)])
    # ruleid: nunchi-formatted-sql-in-execute
    conn.executemany("INSERT INTO %s VALUES (%%s)" % table, [(1,)])
    # ruleid: nunchi-formatted-sql-in-execute
    conn.executemany("INSERT INTO {} VALUES (%s)".format(table), [(1,)])
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute("SELECT * FROM {}".format("t"))
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute(f"SELECT * FROM t", (user,))
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute("SELECT " + "1")
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute("SELECT %s" % "1")


def f_string_conversions(conn, x):
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute(f"SELECT * FROM {x!r}")
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute(f"SELECT * FROM t LIMIT {x:d}")
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute(f"SELECT * FROM t WHERE c = {x!s:>10}")
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute(f"SELECT * FROM t WHERE c = {x=}")


def non_literal_operands(cur, a, b, table):
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute(a + b)
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute(a + " WHERE x = 1" + b)
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute(a % b)
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute(a.format(table))


def augmented_assignment(cur, x):
    q = "SELECT * FROM t WHERE c = "
    q += x
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute(q)

    q2 = "SELECT * FROM t"
    q2 += f" WHERE c = {x}"
    # ruleid: nunchi-formatted-sql-in-execute
    cur.executemany(q2, [(1,)])


def joined(cur, cols, table):
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute("SELECT " + ", ".join(cols) + " FROM t")
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute(" ".join(["SELECT", table]))
    q = ", ".join(cols)
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute(q)


def through_a_variable(cur, table, user):
    q = f"SELECT * FROM {table}"
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute(q)

    q2 = "SELECT * FROM " + table
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute(q2, (user,))

    q3 = "SELECT %s FROM t" % user
    # ruleid: nunchi-formatted-sql-in-execute
    cur.executemany(q3, [(1,)])

    q4 = "SELECT {} FROM t".format(user)
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute(q4)


def through_two_assignments(cur, table):
    base = "SELECT * FROM " + table
    q = base
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute(q)


def copy_sink(cur, table):
    stmt = f"COPY {table} FROM STDIN"
    # ruleid: nunchi-formatted-sql-in-execute
    with cur.copy(stmt) as copy:
        copy.write(b"x")
    # ruleid: nunchi-formatted-sql-in-execute
    cur.copy("COPY " + table + " TO STDOUT")


def keyword_sinks(cur, table):
    # ruleid: nunchi-formatted-sql-in-execute
    cur.execute(query=f"SELECT * FROM {table}")
    # ruleid: nunchi-formatted-sql-in-execute
    cur.copy(statement="COPY " + table + " TO STDOUT")


def build_query(table):
    return f"SELECT * FROM {table}"


def build_percent(table):
    return "SELECT * FROM %s" % table


def build_via_variable(table):
    q = "SELECT * FROM " + table
    return q


def helper_defined_before_use(cur, table):
    # ruleid: nunchi-formatted-sql-from-helper
    cur.execute(build_query(table))
    # ruleid: nunchi-formatted-sql-from-helper
    cur.execute(build_percent(table), ())
    # ruleid: nunchi-formatted-sql-from-helper
    cur.executemany(build_via_variable(table), [(1,)])


class Repo:
    def run(self, cur, table):
        # ruleid: nunchi-formatted-sql-from-helper
        cur.execute(self._query(table))
        # ruleid: nunchi-formatted-sql-from-helper
        cur.execute(late_helper(table))

    def _query(self, table):
        return "SELECT * FROM {}".format(table)


def late_helper(table):
    return f"SELECT * FROM {table}"


def parameterized(conn, user):
    # ok: nunchi-formatted-sql-in-execute
    conn.execute("SELECT * FROM t WHERE u = %s", (user,))
    # ok: nunchi-formatted-sql-in-execute
    conn.execute("SELECT 1")
    q = "SELECT * FROM t WHERE u = %s"
    # ok: nunchi-formatted-sql-in-execute
    conn.execute(q, (user,))


def constant_only(conn):
    # ok: nunchi-formatted-sql-in-execute
    conn.execute("SELECT 1")
    q3 = "SELECT * FROM t"
    q3 += " WHERE c = 1"
    # ok: nunchi-formatted-sql-in-execute
    conn.execute(q3)
    # ok: nunchi-formatted-sql-in-execute
    conn.execute("SELECT 1" " FROM t")


def composed_with_psycopg_sql(conn, sql, table, cols):
    # ok: nunchi-formatted-sql-in-execute
    conn.execute(sql.SQL("SELECT * FROM {}").format(sql.Identifier(table)))
    q = sql.SQL("SELECT {} FROM {}").format(
        sql.SQL(", ").join(map(sql.Identifier, cols)), sql.Identifier(table)
    )
    # ok: nunchi-formatted-sql-in-execute
    conn.execute(q)
    q2 = sql.SQL("SELECT * FROM ") + sql.Identifier(table)
    # ok: nunchi-formatted-sql-in-execute
    conn.execute(q2)


def psycopg_sql_with_formatted_text(conn, sql, table):
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute(sql.SQL(f"SELECT * FROM {table}"))
    # ruleid: nunchi-formatted-sql-in-execute
    conn.execute(sql.SQL("SELECT * FROM {}".format(table)))


def unrelated_formatting(conn, user):
    msg = f"hello {user}"
    print(msg)
    # ok: nunchi-formatted-sql-in-execute
    conn.execute("SELECT 1")
    label = "user: " + user
    # ok: nunchi-formatted-sql-in-execute
    conn.execute("SELECT %s", (label,))


def fixed_helper():
    return "SELECT 1"


def fixed_helper_use(cur):
    # ok: nunchi-formatted-sql-from-helper
    cur.execute(fixed_helper())
    # ok: nunchi-formatted-sql-from-helper
    cur.execute(sql_helper(cur))


def sql_helper(sql):
    return sql.SQL("SELECT {}").format(sql.Identifier("t"))


def message_helper(user):
    return f"hello {user}"


def not_a_sink(log, user):
    # ok: nunchi-formatted-sql-from-helper
    log.info(message_helper(user))
