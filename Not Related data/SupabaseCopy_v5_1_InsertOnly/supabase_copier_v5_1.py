import os
import sys
import shlex
import time
import getpass
import subprocess
import json
import hashlib

try:
    import paramiko
except ImportError:
    print("ERROR: paramiko is not installed.")
    input("Press Enter to exit...")
    sys.exit(1)


ENV_FILE = ".env"


def load_env():
    d = {}
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    d[k.strip()] = v.strip()
    return d


E = load_env()

SRC_CONTAINER = E.get("SOURCE_DB_CONTAINER", "supabase_db_User")
SRC_DB        = E.get("SOURCE_DB_NAME", "postgres")
SRC_USER      = E.get("SOURCE_DB_USER", "postgres")

SSH_USER      = E.get("DEST_SSH_USER", "lakpuedruginc")
SSH_HOST      = E.get("DEST_SSH_HOST", "192.168.0.5")
SSH_PORT      = int(E.get("DEST_SSH_PORT", "22"))

DST_CONTAINER = E.get("DEST_DB_CONTAINER", "supabase-db")
DST_USER      = E.get("DEST_DB_USER", "supabase_admin")
DST_DB        = E.get("DEST_DB_NAME", "postgres")


# ---------------------------------------------------------------------------
# basic helpers
# ---------------------------------------------------------------------------

def section(s):
    print("\n" + "=" * 70)
    print(s)
    print("=" * 70)


def q(s):
    """Quote a SQL identifier."""
    return '"' + s.replace('"', '""') + '"'


def lit(s):
    """Quote a SQL string literal."""
    return "'" + str(s).replace("'", "''") + "'"


def local(args):
    """
    Run a local subprocess.

    IMPORTANT (Windows): subprocess's default text mode uses the system
    ANSI codec (cp1252 here). Postgres text is UTF-8. Forcing utf-8 with
    errors='replace' prevents UnicodeDecodeError on any non-ASCII row.
    """
    return subprocess.run(
        args,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def src_sql(sql):
    r = local([
        "docker", "exec",
        "-e", "PGCLIENTENCODING=UTF8",
        SRC_CONTAINER,
        "psql", "-U", SRC_USER, "-d", SRC_DB,
        "-t", "-A", "-c", sql,
    ])
    if r.returncode:
        raise RuntimeError(r.stderr or r.stdout or "unknown psql error")
    if r.stdout is None:
        raise RuntimeError(
            f"psql produced no stdout (exit={r.returncode}). stderr={r.stderr!r}"
        )
    return r.stdout.strip()


# ---------------------------------------------------------------------------
# destination SSH session with auto-reconnect
# ---------------------------------------------------------------------------

def ssh_connect(password):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(
        SSH_HOST, port=SSH_PORT,
        username=SSH_USER, password=password,
        look_for_keys=False, allow_agent=False,
        timeout=15, banner_timeout=15, auth_timeout=15,
    )
    return c


def _ssh_exec_raw(client, cmd, stdin_data=None, timeout=300):
    i, o, e = client.exec_command(cmd, timeout=timeout)

    if stdin_data is not None:
        if isinstance(stdin_data, str):
            stdin_data = stdin_data.encode("utf-8")
        if hasattr(stdin_data, "read"):
            while True:
                chunk = stdin_data.read(1024 * 1024)
                if not chunk:
                    break
                if isinstance(chunk, str):
                    chunk = chunk.encode("utf-8")
                i.write(chunk)
        else:
            i.write(stdin_data)
        i.flush()
        i.channel.shutdown_write()

    out = o.read().decode("utf-8", errors="replace")
    err = e.read().decode("utf-8", errors="replace")
    rc = o.channel.recv_exit_status()
    return rc, out, err


class DstSession:
    """
    Persistent destination session that transparently reconnects when
    the remote sshd resets the TCP connection (common on Synology).
    """

    MAX_RETRIES = 4
    BACKOFF = 1.5  # seconds; doubles each attempt

    def __init__(self, password):
        self.password = password
        self.client = None

    # -- low level ----------------------------------------------------------

    def _open(self):
        self._close()
        self.client = ssh_connect(self.password)

    def _close(self):
        if self.client is not None:
            try:
                self.client.close()
            except Exception:
                pass
            self.client = None

    def _alive(self):
        if self.client is None:
            return False
        t = self.client.get_transport()
        return t is not None and t.is_active()

    def exec(self, cmd, stdin_data=None, timeout=300):
        last = None
        delay = self.BACKOFF
        for attempt in range(self.MAX_RETRIES):
            try:
                if not self._alive():
                    self._open()
                return _ssh_exec_raw(self.client, cmd, stdin_data, timeout)
            except Exception as ex:
                last = ex
                print(f"    [ssh retry {attempt + 1}/{self.MAX_RETRIES}] {ex}")
                self._close()
                if attempt < self.MAX_RETRIES - 1:
                    time.sleep(delay)
                    delay *= 2
        raise last

    # -- SQL helpers --------------------------------------------------------

    def sql(self, sql, timeout=120):
        """
        Run a single SQL statement, return stdout.

        This goes through a shell (bash -> docker -> psql), so the SQL text
        must be *shell*-quoted, not SQL-quoted. shlex.quote is the right tool.
        """
        cmd = (
            f"sudo -n /usr/local/bin/docker exec "
            f"-e PGCLIENTENCODING=UTF8 "
            f"{DST_CONTAINER} "
            f"psql -U {DST_USER} -d {DST_DB} -t -A -c "
            + shlex.quote(sql)
        )
        rc, out, err = self.exec(cmd, timeout=timeout)
        if rc:
            raise RuntimeError(err or out)
        return out.strip()

    def sql_script(self, script_text, timeout=900):
        """Run a multi-statement SQL script from stdin in one round trip."""
        cmd = (
            f"sudo -n /usr/local/bin/docker exec -i "
            f"-e PGCLIENTENCODING=UTF8 "
            f"{DST_CONTAINER} "
            f"psql -v ON_ERROR_STOP=1 -U {DST_USER} -d {DST_DB}"
        )
        if isinstance(script_text, str):
            script_text = script_text.encode("utf-8")
        rc, out, err = self.exec(cmd, stdin_data=script_text, timeout=timeout)
        if rc:
            raise RuntimeError(err or out)
        return out

    def close(self):
        self._close()


# ---------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------

def discover_tables():
    sql = """
SELECT n.nspname || E'\\t' || c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p')
AND n.nspname NOT LIKE 'pg_%'
AND n.nspname NOT IN (
'_realtime','auth','cron','extensions','graphql','graphql_public',
'information_schema','net','pg_catalog','pg_net','pg_temp_1',
'pg_toast','pg_toast_temp_1','pgbouncer','pgmq','pgsodium',
'pgsodium_masks','realtime','storage','supabase_functions',
'supabase_migrations','vault'
)
ORDER BY n.nspname, c.relname;
"""
    return [
        tuple(x.split("\t", 1))
        for x in src_sql(sql).splitlines()
        if "\t" in x
    ]


# ---------------------------------------------------------------------------
# inspection
# ---------------------------------------------------------------------------

def schema_exists(session, s):
    return session.sql(
        f"SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname={lit(s)});"
    ).lower() == "t"


def table_exists(session, s, t):
    return session.sql(
        f"SELECT to_regclass({lit(s + '.' + t)}) IS NOT NULL;"
    ).lower() == "t"


def get_columns_src(s, t):
    """
    Returns rows of:
      [column_name, data_type, udt_schema, udt_name, is_nullable, column_default]
    """
    sql = f"""
SELECT column_name || E'\\t' || data_type || E'\\t' ||
       coalesce(udt_schema,'') || E'\\t' || coalesce(udt_name,'') || E'\\t' ||
       coalesce(is_nullable,'') || E'\\t' || coalesce(column_default,'')
FROM information_schema.columns
WHERE table_schema = {lit(s)} AND table_name = {lit(t)}
ORDER BY ordinal_position;
"""
    rows = []
    for line in src_sql(sql).splitlines():
        p = line.split("\t")
        if len(p) >= 6:
            rows.append(p)
    return rows


def get_columns_dst(session, s, t):
    out = session.sql(f"""
SELECT column_name || E'\\t' || data_type || E'\\t' ||
       coalesce(udt_schema,'') || E'\\t' || coalesce(udt_name,'') || E'\\t' ||
       coalesce(is_nullable,'') || E'\\t' || coalesce(column_default,'')
FROM information_schema.columns
WHERE table_schema = {lit(s)} AND table_name = {lit(t)}
ORDER BY ordinal_position;
""")
    return [x.split("\t") for x in out.splitlines() if x]


def get_pk_src(s, t):
    out = src_sql(f"""
SELECT kcu.column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name
 AND tc.table_schema    = kcu.table_schema
 AND tc.table_name      = kcu.table_name
WHERE tc.constraint_type = 'PRIMARY KEY'
  AND tc.table_schema    = {lit(s)}
  AND tc.table_name      = {lit(t)}
ORDER BY kcu.ordinal_position;
""")
    return out.splitlines() if out else []


def get_pk_dst(session, s, t):
    out = session.sql(f"""
SELECT kcu.column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name
 AND tc.table_schema    = kcu.table_schema
 AND tc.table_name      = kcu.table_name
WHERE tc.constraint_type = 'PRIMARY KEY'
  AND tc.table_schema    = {lit(s)}
  AND tc.table_name      = {lit(t)}
ORDER BY kcu.ordinal_position;
""")
    return out.splitlines() if out else []


def get_unique_constraints_dst(session, s, t):
    """
    Return ALL unique constraints on the destination table (PK + UNIQUE),
    as a list of (constraint_name, [col1, col2, ...]) tuples.
    """
    out = session.sql(f"""
SELECT tc.constraint_name || E'\\t' || tc.constraint_type || E'\\t' || kcu.column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name
 AND tc.table_schema    = kcu.table_schema
 AND tc.table_name      = kcu.table_name
WHERE tc.constraint_type IN ('PRIMARY KEY', 'UNIQUE')
  AND tc.table_schema    = {lit(s)}
  AND tc.table_name      = {lit(t)}
ORDER BY tc.constraint_name, kcu.ordinal_position;
""")
    grouped = {}
    order = []
    for line in out.splitlines():
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        cname, _ctype, col = parts[0], parts[1], parts[2]
        if cname not in grouped:
            grouped[cname] = []
            order.append(cname)
        grouped[cname].append(col)
    return [(cname, grouped[cname]) for cname in order]


def source_rows(s, t):
    return json.loads(src_sql(
        f"SELECT coalesce(json_agg(x), '[]'::json)::text "
        f"FROM (SELECT * FROM {q(s)}.{q(t)}) x;"
    ) or "[]")


def source_exact_type(s, t, column):
    return src_sql(f"""
SELECT format_type(a.atttypid, a.atttypmod)
FROM pg_attribute a
JOIN pg_class c     ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = {lit(s)}
  AND c.relname = {lit(t)}
  AND a.attname = {lit(column)}
  AND a.attnum  > 0
  AND NOT a.attisdropped;
""")


# ---------------------------------------------------------------------------
# schema changes (additive only)
# ---------------------------------------------------------------------------

def add_missing_columns(session, s, t):
    src = get_columns_src(s, t)
    dst = {r[0]: r for r in get_columns_dst(session, s, t)}
    added = 0
    stmts = []

    for name, datatype, _u_s, _u_n, _nn, _df in src:
        if name in dst:
            continue
        dtype = source_exact_type(s, t, name) or datatype
        # Never NOT NULL, never a default that could rewrite existing rows.
        stmts.append(f"ALTER TABLE {q(s)}.{q(t)} ADD COLUMN {q(name)} {dtype};")
        print(f"    [ADD COLUMN] {name}")
        added += 1

    if stmts:
        session.sql_script("BEGIN;\n" + "\n".join(stmts) + "\nCOMMIT;\n")

    return added


def create_new_table(session, s, t):
    r = local([
        "docker", "exec",
        "-e", "PGCLIENTENCODING=UTF8",
        SRC_CONTAINER,
        "pg_dump", "-U", SRC_USER, "-d", SRC_DB,
        "--schema-only", "--no-owner", "--no-privileges",
        "-t", f"{s}.{t}",
    ])
    if r.returncode:
        raise RuntimeError(r.stderr or r.stdout or "pg_dump failed")
    if not r.stdout:
        raise RuntimeError("pg_dump produced no output")

    # New table only. No --clean, no DROP.
    session.sql_script(r.stdout, timeout=300)


# ---------------------------------------------------------------------------
# type-aware value rendering
# ---------------------------------------------------------------------------

def _column_is_array(col):
    data_type = col[1] if len(col) > 1 else ""
    udt_name  = col[3] if len(col) > 3 else ""
    return data_type == "ARRAY" or (udt_name and udt_name.startswith("_"))


def _column_is_json(col):
    data_type = col[1] if len(col) > 1 else ""
    udt_name  = col[3] if len(col) > 3 else ""
    return data_type in ("json", "jsonb") or udt_name in ("json", "jsonb")


def _render_pg_array_element(v):
    """Recursively render a single array element as a Postgres array token."""
    if v is None:
        return "NULL"
    if isinstance(v, list):
        return "{" + ",".join(_render_pg_array_element(x) for x in v) + "}"
    if isinstance(v, bool):
        return "t" if v else "f"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, dict):
        s = json.dumps(v, separators=(",", ":"), ensure_ascii=False)
        s = s.replace("\\", "\\\\").replace('"', '\\"')
        return '"' + s + '"'
    s = str(v)
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + s + '"'


def render_pg_array(v):
    """Convert a Python list (from JSON) to a Postgres array literal."""
    if v is None:
        return "NULL"
    if not isinstance(v, list):
        v = [v]
    inner = "{" + ",".join(_render_pg_array_element(x) for x in v) + "}"
    return lit(inner)


def sql_value(v, col=None):
    """
    Render a Python value as a SQL literal, using column type info when
    available. col = [name, data_type, udt_schema, udt_name, ...]
    """
    if v is None:
        return "NULL"

    if col is not None:
        if _column_is_array(col):
            return render_pg_array(v)
        if _column_is_json(col):
            return lit(json.dumps(v, separators=(",", ":"), ensure_ascii=False))

    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (dict, list)):
        return lit(json.dumps(v, separators=(",", ":"), ensure_ascii=False))
    return lit(v)


# ---------------------------------------------------------------------------
# data sync (insert only)
# ---------------------------------------------------------------------------

def row_hash(row):
    return hashlib.sha256(
        json.dumps(row, sort_keys=True, separators=(",", ":"), default=str)
        .encode()
    ).hexdigest()


def _row_key(row, cols):
    """A stable, hashable key for the given columns of a row."""
    return json.dumps(
        [row.get(c) for c in cols],
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    )


def _fetch_existing_keys(session, s, t, cols):
    """
    Fetch the set of existing key-values (as JSON strings) for the given
    columns of the destination table. One round trip.
    """
    col_list = ",".join(q(c) for c in cols)
    blob = session.sql(
        f"SELECT coalesce(json_agg(x), '[]'::json)::text "
        f"FROM (SELECT {col_list} FROM {q(s)}.{q(t)}) x;"
    )
    return {
        _row_key(r, cols)
        for r in json.loads(blob or "[]")
    }


def sync_rows(session, s, t, pk):
    rows = source_rows(s, t)
    if not rows:
        return 0

    columns = get_columns_src(s, t)
    names = [x[0] for x in columns]

    # Every unique constraint on the destination (PK + UNIQUE).
    uniq = get_unique_constraints_dst(session, s, t)

    if uniq:
        # Build a "seen" set for each constraint.
        seen_sets = []
        for cname, cols in uniq:
            seen = _fetch_existing_keys(session, s, t, cols)
            seen_sets.append((cname, cols, seen))

        new_rows = []
        for row in rows:
            conflict = None
            for cname, cols, seen in seen_sets:
                if _row_key(row, cols) in seen:
                    conflict = cname
                    break
            if conflict:
                continue
            new_rows.append(row)
            # Also record this row's keys so we catch duplicates within source.
            for cname, cols, seen in seen_sets:
                seen.add(_row_key(row, cols))
    else:
        # No unique constraints at all — fall back to row-hash comparison.
        dest_rows = json.loads(session.sql(
            f"SELECT coalesce(json_agg(x), '[]'::json)::text "
            f"FROM (SELECT * FROM {q(s)}.{q(t)}) x;"
        ) or "[]")
        seen = {row_hash(r) for r in dest_rows}
        new_rows = []
        for r in rows:
            h = row_hash(r)
            if h not in seen:
                new_rows.append(r)
                seen.add(h)

    if not new_rows:
        return 0

    # Batch every INSERT in one round trip.
    # ON CONFLICT DO NOTHING is a final safety net for constraints we did
    # not pre-check (partial indexes, exclusion constraints, etc.).
    col_list = ",".join(q(n) for n in names)
    stmts = []
    for row in new_rows:
        vals = ",".join(
            sql_value(row.get(col[0]), col) for col in columns
        )
        stmts.append(
            f"INSERT INTO {q(s)}.{q(t)} ({col_list}) VALUES ({vals}) "
            f"ON CONFLICT DO NOTHING;"
        )

    script = "BEGIN;\n" + "\n".join(stmts) + "\nCOMMIT;\n"
    session.sql_script(script, timeout=900)

    return len(new_rows)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    section("SUPABASE INCREMENTAL COPIER v5.6 - INSERT ONLY")

    print("Laptop SOURCE  ->  Synology DESTINATION")
    print()
    print("SAFETY RULES:")
    print("  [YES] Add missing schema")
    print("  [YES] Add missing table")
    print("  [YES] Add missing column")
    print("  [YES] Insert missing row")
    print("  [NO ] UPDATE existing row")
    print("  [NO ] DELETE existing row")
    print("  [NO ] DROP existing table")
    print("  [NO ] DROP existing schema")
    print("  [NO ] Replace existing values")
    print()
    print("SSH password is requested ONCE.")

    password = getpass.getpass("\nSSH password: ")
    session = None

    try:
        tables = discover_tables()
        if not tables:
            raise RuntimeError("No custom source tables were found.")

        print("\nDiscovered custom tables:")
        for s, t in tables:
            print(f"  - {s}.{t}")

        session = DstSession(password)

        rc, out, err = session.exec(
            "sudo -n /usr/local/bin/docker ps --format '{{.Names}}'"
        )
        if rc or DST_CONTAINER not in out.splitlines():
            raise RuntimeError(
                f"Destination container '{DST_CONTAINER}' is not accessible."
            )

        section("SCHEMA / TABLE / COLUMN CHECK")

        for s, t in tables:
            if not schema_exists(session, s):
                print(f"[ADD SCHEMA] {s}")
                session.sql(f"CREATE SCHEMA {q(s)};")

            if not table_exists(session, s, t):
                print(f"[ADD TABLE] {s}.{t}")
                create_new_table(session, s, t)
            else:
                print(f"[KEEP TABLE] {s}.{t}")
                add_missing_columns(session, s, t)

        section("INSERT-ONLY DATA SYNC")

        total_added = 0

        for s, t in tables:
            src_pk = get_pk_src(s, t)
            dst_pk = get_pk_dst(session, s, t)

            if src_pk and src_pk == dst_pk:
                added = sync_rows(session, s, t, src_pk)
                method = "PRIMARY KEY"
            else:
                added = sync_rows(session, s, t, [])
                method = "ROW HASH"

            total_added += added
            print(f"{s}.{t}: +{added} new row(s) [{method}]")

        section("SYNC COMPLETED SUCCESSFULLY")

        print(f"Total new rows inserted: {total_added}")
        print()
        print("Existing destination rows were NOT updated.")
        print("Existing destination rows were NOT deleted.")
        print("Existing destination tables were NOT dropped.")
        print("Existing destination schemas were NOT dropped.")

    except Exception as e:
        section("SYNC FAILED")
        print(str(e))

    finally:
        if session:
            session.close()

    input("\nPress Enter to exit...")


if __name__ == "__main__":
    main()