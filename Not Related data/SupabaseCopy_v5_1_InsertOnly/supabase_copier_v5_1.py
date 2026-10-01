import os
import sys
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
    d={}
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE, encoding="utf-8") as f:
            for line in f:
                line=line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k,v=line.split("=",1)
                    d[k.strip()]=v.strip()
    return d

E=load_env()
SRC_CONTAINER=E.get("SOURCE_DB_CONTAINER","supabase_db_User")
SRC_DB=E.get("SOURCE_DB_NAME","postgres")
SRC_USER=E.get("SOURCE_DB_USER","postgres")
SSH_USER=E.get("DEST_SSH_USER","lakpuedruginc")
SSH_HOST=E.get("DEST_SSH_HOST","192.168.0.5")
SSH_PORT=int(E.get("DEST_SSH_PORT","22"))
DST_CONTAINER=E.get("DEST_DB_CONTAINER","supabase-db")
DST_USER=E.get("DEST_DB_USER","supabase_admin")
DST_DB=E.get("DEST_DB_NAME","postgres")

EXCLUDED={
    "_realtime","auth","cron","extensions","graphql","graphql_public",
    "information_schema","net","pg_catalog","pg_net","pg_temp_1",
    "pg_toast","pg_toast_temp_1","pgbouncer","pgmq","pgsodium",
    "pgsodium_masks","realtime","storage","supabase_functions",
    "supabase_migrations","vault"
}

def section(s):
    print("\n"+"="*70)
    print(s)
    print("="*70)

def q(s):
    return '"' + s.replace('"','""') + '"'

def lit(s):
    return "'" + str(s).replace("'","''") + "'"

def local(args):
    return subprocess.run(args, text=True, capture_output=True)

def src_sql(sql):
    r=local([
        "docker","exec",SRC_CONTAINER,
        "psql","-U",SRC_USER,"-d",SRC_DB,
        "-t","-A","-c",sql
    ])
    if r.returncode:
        raise RuntimeError(r.stderr or r.stdout)
    return r.stdout.strip()

def ssh_connect(password):
    c=paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(
        SSH_HOST, port=SSH_PORT,
        username=SSH_USER, password=password,
        look_for_keys=False, allow_agent=False,
        timeout=15, banner_timeout=15, auth_timeout=15
    )
    return c

def ssh_exec(c, cmd, stdin_data=None, timeout=300):
    i,o,e=c.exec_command(cmd, timeout=timeout)
    if stdin_data is not None:
        if hasattr(stdin_data,"read"):
            while True:
                chunk=stdin_data.read(1024*1024)
                if not chunk: break
                i.write(chunk)
        else:
            i.write(stdin_data)
        i.flush()
        i.channel.shutdown_write()
    out=o.read().decode("utf-8",errors="replace")
    err=e.read().decode("utf-8",errors="replace")
    rc=o.channel.recv_exit_status()
    return rc,out,err

def dst_sql(c,sql):
    cmd=(
        f"sudo -n /usr/local/bin/docker exec {DST_CONTAINER} "
        f"psql -U {DST_USER} -d {DST_DB} -t -A -c "
        + lit(sql)
    )
    rc,out,err=ssh_exec(c,cmd,timeout=120)
    if rc:
        raise RuntimeError(err or out)
    return out.strip()

def discover_tables():
    sql="""
SELECT n.nspname||E'\\t'||c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind IN ('r','p')
AND n.nspname NOT LIKE 'pg_%'
AND n.nspname NOT IN (
'_realtime','auth','cron','extensions','graphql','graphql_public',
'information_schema','net','pg_catalog','pg_net','pg_temp_1',
'pg_toast','pg_toast_temp_1','pgbouncer','pgmq','pgsodium',
'pgsodium_masks','realtime','storage','supabase_functions',
'supabase_migrations','vault'
)
ORDER BY n.nspname,c.relname;
"""
    return [
        tuple(x.split("\t",1))
        for x in src_sql(sql).splitlines()
        if "\t" in x
    ]

def schema_exists(c,s):
    return dst_sql(
        c,
        f"SELECT EXISTS("
        f"SELECT 1 FROM pg_namespace WHERE nspname={lit(s)});"
    ).lower()=="t"

def table_exists(c,s,t):
    return dst_sql(
        c,
        f"SELECT to_regclass({lit(s+'.'+t)}) IS NOT NULL;"
    ).lower()=="t"

def get_columns_src(s,t):
    sql=f"""
SELECT column_name||E'\\t'||data_type||E'\\t'||coalesce(udt_schema,'')||
E'\\t'||coalesce(udt_name,'')||E'\\t'||coalesce(is_nullable,'')||
E'\\t'||coalesce(column_default,'')
FROM information_schema.columns
WHERE table_schema={lit(s)} AND table_name={lit(t)}
ORDER BY ordinal_position;
"""
    rows=[]
    for line in src_sql(sql).splitlines():
        p=line.split("\t")
        if len(p)>=6:
            rows.append(p)
    return rows

def get_columns_dst(c,s,t):
    out=dst_sql(c,f"""
SELECT column_name||E'\\t'||data_type||E'\\t'||coalesce(udt_schema,'')||
E'\\t'||coalesce(udt_name,'')||E'\\t'||coalesce(is_nullable,'')||
E'\\t'||coalesce(column_default,'')
FROM information_schema.columns
WHERE table_schema={lit(s)} AND table_name={lit(t)}
ORDER BY ordinal_position;
""")
    return [x.split("\t") for x in out.splitlines() if x]

def get_pk_src(s,t):
    out=src_sql(f"""
SELECT kcu.column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
ON tc.constraint_name=kcu.constraint_name
AND tc.table_schema=kcu.table_schema
AND tc.table_name=kcu.table_name
WHERE tc.constraint_type='PRIMARY KEY'
AND tc.table_schema={lit(s)}
AND tc.table_name={lit(t)}
ORDER BY kcu.ordinal_position;
""")
    return out.splitlines() if out else []

def get_pk_dst(c,s,t):
    out=dst_sql(c,f"""
SELECT kcu.column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
ON tc.constraint_name=kcu.constraint_name
AND tc.table_schema=kcu.table_schema
AND tc.table_name=kcu.table_name
WHERE tc.constraint_type='PRIMARY KEY'
AND tc.table_schema={lit(s)}
AND tc.table_name={lit(t)}
ORDER BY kcu.ordinal_position;
""")
    return out.splitlines() if out else []

def source_rows(s,t):
    # JSON is used only to transfer data. Source is never modified.
    return json.loads(src_sql(
        f"SELECT coalesce(json_agg(x),'[]'::json)::text "
        f"FROM (SELECT * FROM {q(s)}.{q(t)}) x;"
    ) or "[]")

def source_exact_type(s,t,column):
    return src_sql(f"""
SELECT format_type(a.atttypid,a.atttypmod)
FROM pg_attribute a
JOIN pg_class c ON c.oid=a.attrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname={lit(s)}
AND c.relname={lit(t)}
AND a.attname={lit(column)}
AND a.attnum>0
AND NOT a.attisdropped;
""")

def add_missing_columns(c,s,t):
    src=get_columns_src(s,t)
    dst={r[0]:r for r in get_columns_dst(c,s,t)}
    added=0

    for name,datatype,udt_schema,udt_name,nullable,default in src:
        if name in dst:
            continue

        dtype=source_exact_type(s,t,name) or datatype

        # Never make a new column NOT NULL when destination already has rows.
        # Never copy a default that could alter existing rows.
        sql=f"ALTER TABLE {q(s)}.{q(t)} ADD COLUMN {q(name)} {dtype};"
        dst_sql(c,sql)

        print(f"    [ADD COLUMN] {name}")
        added += 1

    return added

def create_new_table(c,s,t):
    cmd=[
        "docker","exec",SRC_CONTAINER,
        "pg_dump","-U",SRC_USER,"-d",SRC_DB,
        "--schema-only","--no-owner","--no-privileges",
        "-t",f"{s}.{t}"
    ]
    r=subprocess.run(cmd,text=True,capture_output=True)
    if r.returncode:
        raise RuntimeError(r.stderr)

    # New table only. No --clean and no DROP.
    rc,out,err=ssh_exec(
        c,
        f"sudo -n /usr/local/bin/docker exec -i {DST_CONTAINER} "
        f"psql -v ON_ERROR_STOP=1 -U {DST_USER} -d {DST_DB}",
        r.stdout,
        timeout=300
    )
    if rc:
        raise RuntimeError(err or out)

def sql_value(v):
    if v is None:
        return "NULL"
    if isinstance(v,bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v,(int,float)):
        return str(v)
    if isinstance(v,(dict,list)):
        return lit(json.dumps(v,separators=(",",":"),ensure_ascii=False))
    return lit(v)

def insert_one(c,s,t,row,columns):
    names=[x[0] for x in columns]
    values=[sql_value(row.get(n)) for n in names]
    sql=(
        f"INSERT INTO {q(s)}.{q(t)} "
        f"({','.join(q(n) for n in names)}) "
        f"VALUES ({','.join(values)});"
    )
    dst_sql(c,sql)

def row_hash(row):
    return hashlib.sha256(
        json.dumps(row,sort_keys=True,separators=(",",":"),default=str).encode()
    ).hexdigest()

def sync_rows(c,s,t,pk):
    rows=source_rows(s,t)
    if not rows:
        return 0

    columns=get_columns_src(s,t)
    names=[x[0] for x in columns]

    # PRIMARY KEY path: only INSERT when the exact PK does not exist.
    if pk:
        added=0
        for row in rows:
            where_parts=[]
            for k in pk:
                v=row.get(k)
                if v is None:
                    where_parts.append(f"{q(k)} IS NULL")
                else:
                    where_parts.append(f"{q(k)} = {sql_value(v)}")
            where=" AND ".join(where_parts)

            exists=dst_sql(
                c,
                f"SELECT EXISTS("
                f"SELECT 1 FROM {q(s)}.{q(t)} WHERE {where});"
            ).lower()=="t"

            if exists:
                continue

            insert_one(c,s,t,row,columns)
            added += 1
        return added

    # No PK: compare complete rows by canonical hash.
    dst_json=dst_sql(
        c,
        f"SELECT coalesce(json_agg(x),'[]'::json)::text "
        f"FROM (SELECT * FROM {q(s)}.{q(t)}) x;"
    )
    dest_rows=json.loads(dst_json or "[]")
    existing={row_hash(r) for r in dest_rows}

    added=0
    for row in rows:
        h=row_hash(row)
        if h in existing:
            continue
        insert_one(c,s,t,row,columns)
        existing.add(h)
        added += 1

    return added

def main():
    section("SUPABASE INCREMENTAL COPIER v5.1 - INSERT ONLY")

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

    password=getpass.getpass("\nSSH password: ")
    client=None

    try:
        tables=discover_tables()
        if not tables:
            raise RuntimeError("No custom source tables were found.")

        print("\nDiscovered custom tables:")
        for s,t in tables:
            print(f"  - {s}.{t}")

        client=ssh_connect(password)

        rc,out,err=ssh_exec(
            client,
            "sudo -n /usr/local/bin/docker ps --format '{{.Names}}'"
        )
        if rc or DST_CONTAINER not in out.splitlines():
            raise RuntimeError(
                f"Destination container '{DST_CONTAINER}' is not accessible."
            )

        section("SCHEMA / TABLE / COLUMN CHECK")

        for s,t in tables:
            if not schema_exists(client,s):
                print(f"[ADD SCHEMA] {s}")
                dst_sql(client,f"CREATE SCHEMA {q(s)};")

            if not table_exists(client,s,t):
                print(f"[ADD TABLE] {s}.{t}")
                create_new_table(client,s,t)
            else:
                print(f"[KEEP TABLE] {s}.{t}")
                add_missing_columns(client,s,t)

        section("INSERT-ONLY DATA SYNC")

        total_added=0

        for s,t in tables:
            src_pk=get_pk_src(s,t)
            dst_pk=get_pk_dst(client,s,t)

            # Existing PK must match before using it as the unique key.
            if src_pk and src_pk == dst_pk:
                added=sync_rows(client,s,t,src_pk)
                method="PRIMARY KEY"
            else:
                added=sync_rows(client,s,t,[])
                method="ROW HASH"

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
        if client:
            client.close()

    input("\nPress Enter to exit...")

if __name__=="__main__":
    main()
