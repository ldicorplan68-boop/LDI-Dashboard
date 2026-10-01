-- ============================================================================
--  SampleDB / sample_db.sql
--  LDI Sales Dashboard - sample Supabase (PostgreSQL) database
-- ============================================================================
--  Replaces the sample spreadsheets that used to sit in this folder:
--
--      users.csv           -> public.users
--      hero_buttons.csv    -> public.hero_buttons
--      sidebar_buttons.csv -> public.sidebar_buttons
--      shared_items.csv    -> public.shared_items
--      file_passwords.csv  -> public.file_passwords
--      (no sheet)          -> public.folder_limits   (storage quota per folder)
--
--  Columns follow what the app really reads and writes (mis.html,
--  dashboard.html, index.html, settings/*.html), so the seed data is usable:
--
--      users           : allowed_hero_buttons / assigned_* / approver are jsonb
--      hero_buttons    : id, label, href, sort_order
--      sidebar_buttons : id(text), bucket, folder, sort_order, icon, label,
--                        link, roles(jsonb)      <- csv "href" is "link"
--                        (the csv "path" column is unused by the app)
--      shared_items    : owner_*, visibility, allowed_users(jsonb),
--                        password_hash / password_salt
--      file_passwords  : password_hash / password_salt = sha256(salt|password)
--
--  HOW TO RUN
--  ----------
--    Supabase Studio (local) : http://127.0.0.1:54323 -> SQL Editor -> Run
--    psql                    : psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f sample_db.sql
--
--  The script is idempotent (create table if not exists / drop policy if
--  exists / on conflict do nothing), so it is safe to run more than once.
--
--  NOTES
--  -----
--  * mis.html reads bucket 'department' and folder = <page name>, e.g.
--    mis.html -> ROOT 'mis'; folder-setting.html -> bucket 'department'.
--  * sidebar_buttons.roles is compared against superadmin / admin / user.
--  * users.allowed_hero_buttons takes ["all"] (shows the "All" badge) or a
--    hero_buttons id / label.
--  The rows below keep the values of the original spreadsheets (bucket
--  'public', folder '/') so the conversion stays 1:1 - treat them as
--  reference data, and re-point bucket/folder to show them in the UI.
--  * hero_buttons.csv had a shifted header (5 values for 4 columns); the rows
--    here are written with the correct 4 columns.
--  * users.password stays plain text because the login code accepts the plain
--    text or the sha256 hex of the plain text.
--  * The RLS policies below are wide open (using (true)) - fine for a local
--    sample database, tighten them before production.
-- ============================================================================



-- ============================================================================
--  0. EXTENSIONS
-- ============================================================================
create extension if not exists pgcrypto;


-- ============================================================================
--  1. TABLES
-- ============================================================================

-- ---------------------------------------------------------------- users -----
--  Login accounts: used by index.html (login), dashboard.html (hero buttons)
--  and settings/user-setting.html (admin CRUD).
create table if not exists public.users (
  id                        bigserial   primary key,
  username                  text        not null unique,
  password                  text        not null default '',
  full_name                 text        not null default '',
  contact                   bigint,
  email                     text        not null default '',
  role                      text        not null default 'user',       -- superadmin | admin | user
  status                    text        not null default 'pending',    -- active | inactive | pending
  allowed_hero_buttons      jsonb       not null default '[]'::jsonb,  -- ["all"] or [1,2] or ["Reports"]
  assigned_companies        jsonb       not null default '[]'::jsonb,
  assigned_sales_rep_codes  jsonb       not null default '[]'::jsonb,
  assigned_areas            jsonb       not null default '[]'::jsonb,
  approver                  jsonb       not null default '[]'::jsonb,  -- max 3 e-mail addresses
  department                text        not null default '',
  position                  text        not null default '',
  created_at                timestamptz not null default now()
);

-- --------------------------------------------------------- hero_buttons -----
--  Catalog behind the dashboard hero buttons; read by dashboard.html and
--  settings/user-setting.html.
create table if not exists public.hero_buttons (
  id          bigserial primary key,
  label       text      not null,
  href        text      not null default '#',
  sort_order  integer   not null default 0
);

-- ------------------------------------------------------ sidebar_buttons -----
--  File-manager sidebar catalog. Ids are text because mis.html uses values
--  such as 'files', 'opt2' and 'btn_xxxxx'.
create table if not exists public.sidebar_buttons (
  id          text      primary key,
  bucket      text      not null default 'department',
  folder      text      not null default '/',
  sort_order  integer   not null default 0,
  icon        text      not null default U&'\D83D\DCC1',   -- folder icon (DEFAULT_ICON)
  label       text      not null default 'Untitled',
  link        text      not null default '',
  roles       jsonb     not null default '[]'::jsonb
);

-- --------------------------------------------------------- shared_items -----
--  Files/folders shared with other users (mis.html -> Shared with me).
create table if not exists public.shared_items (
  id             text        primary key,
  bucket         text        not null default 'department',
  folder         text        not null default '/',
  path           text        not null,
  name           text        not null default '',
  is_folder      boolean     not null default false,
  owner_id       text        not null default '',
  owner_username text        not null default '',
  owner_display  text        not null default '',
  visibility     text        not null default 'company',   -- company | admin | specific
  allowed_users  jsonb       not null default '[]'::jsonb,
  password_hash  text,
  password_salt  text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  expires_at     timestamptz
);

-- ------------------------------------------------------ file_passwords -----
--  Per-file password protection: password_hash = sha256(salt + '|' + password)
--  as hexadecimal, exactly like hashPassword() in mis.html.
create table if not exists public.file_passwords (
  id             text        primary key,
  bucket         text        not null default 'department',
  folder         text        not null default '/',
  path           text        not null,
  owner_id       text        not null default '',
  password_hash  text        not null,
  password_salt  text        not null,
  created_at     timestamptz not null default now(),
  expires_at     timestamptz
);

-- ------------------------------------------------------- folder_limits -----
--  Storage quota per bucket/folder. Same definition the app prints when the
--  table is missing (settings/folder-setting.html).
create table if not exists public.folder_limits (
  id          bigserial primary key,
  bucket      text not null default 'department',
  folder      text not null,
  limit_bytes bigint,
  note        text default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);


-- ============================================================================
--  2. INDEXES
-- ============================================================================
-- hero_buttons: dashboard.html orders by sort_order then id
create index if not exists hero_buttons_sort_idx
  on public.hero_buttons (sort_order, id);

-- sidebar_buttons: mis.html filters bucket + folder, orders by sort_order
create index if not exists sidebar_buttons_lookup_idx
  on public.sidebar_buttons (bucket, folder, sort_order);

-- shared_items: mis.html filters bucket + folder + path
create index if not exists shared_items_lookup_idx
  on public.shared_items (bucket, folder, path);

-- file_passwords: one row per file (the app deletes the row before inserting)
create unique index if not exists file_passwords_lookup_key
  on public.file_passwords (bucket, folder, path);

-- folder_limits: one limit per bucket + folder (copied from folder-setting.html)
create unique index if not exists folder_limits_bucket_folder_key
  on public.folder_limits (bucket, folder);


-- ============================================================================
--  3. ROW LEVEL SECURITY + POLICIES
-- ============================================================================
--  The browser talks to PostgREST with the anon key, so every table needs a
--  policy for each operation the app performs.
alter table public.users enable row level security;

drop policy if exists "users read"   on public.users;
drop policy if exists "users insert" on public.users;
drop policy if exists "users update" on public.users;
drop policy if exists "users delete" on public.users;

create policy "users read"   on public.users for select using (true);
create policy "users insert" on public.users for insert with check (true);
create policy "users update" on public.users for update using (true);
create policy "users delete" on public.users for delete using (true);

alter table public.hero_buttons enable row level security;

drop policy if exists "hero_buttons read"   on public.hero_buttons;
drop policy if exists "hero_buttons insert" on public.hero_buttons;
drop policy if exists "hero_buttons update" on public.hero_buttons;
drop policy if exists "hero_buttons delete" on public.hero_buttons;

create policy "hero_buttons read"   on public.hero_buttons for select using (true);
create policy "hero_buttons insert" on public.hero_buttons for insert with check (true);
create policy "hero_buttons update" on public.hero_buttons for update using (true);
create policy "hero_buttons delete" on public.hero_buttons for delete using (true);

alter table public.sidebar_buttons enable row level security;

drop policy if exists "sidebar_buttons read"   on public.sidebar_buttons;
drop policy if exists "sidebar_buttons insert" on public.sidebar_buttons;
drop policy if exists "sidebar_buttons update" on public.sidebar_buttons;
drop policy if exists "sidebar_buttons delete" on public.sidebar_buttons;

create policy "sidebar_buttons read"   on public.sidebar_buttons for select using (true);
create policy "sidebar_buttons insert" on public.sidebar_buttons for insert with check (true);
create policy "sidebar_buttons update" on public.sidebar_buttons for update using (true);
create policy "sidebar_buttons delete" on public.sidebar_buttons for delete using (true);

alter table public.shared_items enable row level security;

drop policy if exists "shared_items read"   on public.shared_items;
drop policy if exists "shared_items insert" on public.shared_items;
drop policy if exists "shared_items update" on public.shared_items;
drop policy if exists "shared_items delete" on public.shared_items;

create policy "shared_items read"   on public.shared_items for select using (true);
create policy "shared_items insert" on public.shared_items for insert with check (true);
create policy "shared_items update" on public.shared_items for update using (true);
create policy "shared_items delete" on public.shared_items for delete using (true);

alter table public.file_passwords enable row level security;

drop policy if exists "file_passwords read"   on public.file_passwords;
drop policy if exists "file_passwords insert" on public.file_passwords;
drop policy if exists "file_passwords update" on public.file_passwords;
drop policy if exists "file_passwords delete" on public.file_passwords;

create policy "file_passwords read"   on public.file_passwords for select using (true);
create policy "file_passwords insert" on public.file_passwords for insert with check (true);
create policy "file_passwords update" on public.file_passwords for update using (true);
create policy "file_passwords delete" on public.file_passwords for delete using (true);

alter table public.folder_limits enable row level security;

drop policy if exists "folder_limits read"   on public.folder_limits;
drop policy if exists "folder_limits insert" on public.folder_limits;
drop policy if exists "folder_limits update" on public.folder_limits;
drop policy if exists "folder_limits delete" on public.folder_limits;

create policy "folder_limits read"   on public.folder_limits for select using (true);
create policy "folder_limits insert" on public.folder_limits for insert with check (true);
create policy "folder_limits update" on public.folder_limits for update using (true);
create policy "folder_limits delete" on public.folder_limits for delete using (true);


-- ============================================================================
--  4. GRANTS
-- ============================================================================
--  Supabase grants these automatically for new tables; the block keeps the
--  script valid on a plain PostgreSQL server too.
do $$
declare
  tbl       text;
  role_list text;
begin
  select string_agg(quote_ident(r.rolname), ', ')
    into role_list
    from pg_roles r
   where r.rolname in ('anon', 'authenticated', 'service_role');

  if role_list is null then
    raise notice 'No Supabase API roles found - skipping grants.';
    return;
  end if;

  foreach tbl in array array[
    'users', 'hero_buttons', 'sidebar_buttons',
    'shared_items', 'file_passwords', 'folder_limits'
  ]
  loop
    execute format('grant select, insert, update, delete on public.%I to %s', tbl, role_list);
  end loop;

  execute format('grant usage, select on all sequences in schema public to %s', role_list);
end $$;


-- ============================================================================
--  5. SEED DATA
-- ============================================================================

-- ------------------------------------------- 5.1 users (from users.csv) -----
--  allowed_hero_buttons: ["all"] = every hero button, otherwise hero_buttons
--  id / label.  approver: up to 3 account e-mails (user-setting.html).
insert into public.users
  (id, username, password, full_name, contact, email, role, status,
   allowed_hero_buttons, assigned_companies, assigned_sales_rep_codes,
   assigned_areas, department, approver, position)
values
  (1, 'admin@ldi.com', 'admin123', 'Albert Reyes', 9171234567, 'admin@ldi.com',
   'admin', 'active', '["all"]'::jsonb, '["LDI"]'::jsonb, '[]'::jsonb,
   '["Manila","North Luzon","South Luzon"]'::jsonb, 'HRMD',
   '["miguel.torres@ldi.com"]'::jsonb, 'HR Manager'),

  (2, 'juan.delacruz@ldi.com', 'password123', 'Juan Dela Cruz', 9182345678,
   'juan.delacruz@ldi.com', 'user', 'active',
   '["ART","CNC","HR","OTC SALES","PAYROLL"]'::jsonb, '["LDI"]'::jsonb,
   '["SR002"]'::jsonb, '["Manila"]'::jsonb, 'PAYROLL',
   '["admin@ldi.com","miguel.torres@ldi.com"]'::jsonb, 'HR Supervisor'),

  (3, 'maria.santos@ldi.com', 'maria2024', 'Maria Santos', 9193456789,
   'maria.santos@ldi.com', 'user', 'pending',
   '["ART","CNC","HR","OTC SALES","PAYROLL"]'::jsonb, '["FEI"]'::jsonb,
   '["SR003"]'::jsonb, '["Visayas"]'::jsonb, 'MIS',
   '["admin@ldi.com"]'::jsonb, 'MIS Manager'),

  (4, 'pedro.sison@ldi.com', 'pedro2024', 'Pedro Sison', 9204567890,
   'pedro.sison@ldi.com', 'user', 'active', '["CNC"]'::jsonb,
   '["FEI","LCPI"]'::jsonb, '["SR004"]'::jsonb, '["Mindanao"]'::jsonb, 'ART',
   '["admin@ldi.com"]'::jsonb, 'Graphic Artist'),

  (5, 'carlos.belen@ldi.com', 'carlos123', 'Carlos Belen', 9215678901,
   'carlos.belen@ldi.com', 'user', 'active', '["MIS"]'::jsonb,
   '["LDI","FEI"]'::jsonb, '["SR005"]'::jsonb, '["Mindanao"]'::jsonb, 'CNC',
   '["admin@ldi.com"]'::jsonb, 'Encoder'),

  (6, 'miguel.torres@ldi.com', 'miguel2024', 'Miguel Torres', 9226789012,
   'miguel.torres@ldi.com', 'superadmin', 'active', '["all"]'::jsonb,
   '["ALL"]'::jsonb, '[]'::jsonb, '["North Luzon"]'::jsonb, '', '[]'::jsonb,
   'Corplan')
on conflict (id) do nothing;


-- ------------------------------------- 5.2 hero_buttons (hero_buttons.csv) --
--  The dashboard renders every catalog row whose id or label appears in
--  users.allowed_hero_buttons.  hero_buttons.csv had a shifted header
--  (id,label,href,slug,sort_order); only the four real columns are kept here.
insert into public.hero_buttons (id, label, href, sort_order) values
  (1, 'Sales Dashboard', '/dashboard', 1),
  (2, 'Inventory',       '/inventory', 2),
  (3, 'ART Files',       '/art',       3),
  (4, 'Reports',         '/reports',   4),
  (5, 'Settings',        '/settings',  5)
on conflict (id) do nothing;


-- ------------------------------- 5.3 sidebar_buttons (sidebar_buttons.csv) --
--  csv "href" -> link and csv "path" is unused by mis.html; icon keeps the
--  column default (the folder icon used as DEFAULT_ICON).
insert into public.sidebar_buttons (id, bucket, folder, sort_order, label, link, roles) values
  ('1', 'public', '/',         1, 'Home',            '/',          '["admin","manager","sales_rep"]'::jsonb),
  ('2', 'public', 'dashboard', 2, 'Dashboard',       '/dashboard', '["admin","manager","sales_rep"]'::jsonb),
  ('3', 'public', 'art',       3, 'ART Gallery',     '/art',       '["admin","manager","sales_rep","art_editor"]'::jsonb),
  ('4', 'public', 'files',     4, 'File Manager',    '/files',     '["admin","manager"]'::jsonb),
  ('5', 'public', 'inventory', 5, 'Inventory',       '/inventory', '["admin","manager","sales_rep"]'::jsonb),
  ('6', 'public', 'reports',   6, 'Reports',         '/reports',   '["admin","manager"]'::jsonb),
  ('7', 'public', 'users',     7, 'User Management', '/users',     '["admin","manager"]'::jsonb)
on conflict (id) do nothing;


-- ------------------------------------ 5.4 shared_items (shared_items.csv) --
--  The csv column "user_email" is the recipient, so the rows become
--  visibility 'specific' with that address in allowed_users; "user_full_name"
--  becomes owner_display and "shared_at" fills created_at / updated_at.
insert into public.shared_items
  (id, bucket, folder, path, name, is_folder, owner_id, owner_username,
   owner_display, visibility, allowed_users, created_at, updated_at, expires_at)
values
  ('sh_001_abc', 'public', 'documents', 'price_list_2024.pdf',
   'price_list_2024.pdf', false, '', 'maria.santos@ldi.com', 'Maria Santos',
   'specific', '["maria.santos@ldi.com"]'::jsonb,
   '2024-06-01T10:30:00Z', '2024-06-01T10:30:00Z', '2024-06-08T10:30:00Z'),

  ('sh_002_def', 'public', 'images', 'ldi1.png', 'ldi1.png', false, '',
   'juan.delacruz@ldi.com', 'Juan Dela Cruz', 'specific',
   '["juan.delacruz@ldi.com"]'::jsonb,
   '2024-06-05T14:00:00Z', '2024-06-05T14:00:00Z', '2024-06-12T14:00:00Z'),

  ('sh_003_ghi', 'private', 'sales', 'manila_q1_report.xlsx',
   'manila_q1_report.xlsx', false, '', 'carlos.belen@ldi.com', 'Carlos Belen',
   'specific', '["carlos.belen@ldi.com"]'::jsonb,
   '2024-07-10T09:15:00Z', '2024-07-10T09:15:00Z', '2024-07-17T09:15:00Z'),

  ('sh_004_jkl', 'public', 'templates', 'contract_template.docx',
   'contract_template.docx', false, '', 'pedro.sison@ldi.com', 'Pedro Sison',
   'specific', '["pedro.sison@ldi.com"]'::jsonb,
   '2024-08-01T16:45:00Z', '2024-08-01T16:45:00Z', '2024-08-08T16:45:00Z'),

  ('sh_005_mno', 'private', 'art', 'banner_ldi_2024.psd',
   'banner_ldi_2024.psd', false, '', 'miguel.torres@ldi.com', 'Miguel Torres',
   'specific', '["miguel.torres@ldi.com"]'::jsonb,
   '2024-09-20T11:00:00Z', '2024-09-20T11:00:00Z', '2024-09-27T11:00:00Z')
on conflict (id) do nothing;


-- -------------------------------- 5.5 file_passwords (file_passwords.csv) --
--  password_hash = sha256(password_salt || '|' || password) in hexadecimal,
--  the format mis.html writes and checks.  The plain-text sample passwords
--  are kept as comments so the seeded rows can actually be unlocked:
--      fp_001_abc = ldi2024!        fp_002_def = price2024!
--      fp_003_ghi = tmpl2024!       fp_004_jkl = q1manila2024!
--      fp_005_mno = artpass2024!
insert into public.file_passwords
  (id, bucket, folder, path, owner_id, password_salt, password_hash,
   created_at, expires_at)
values
  ('fp_001_abc', 'public', 'images', 'logo.gif', '',      -- password: ldi2024!
   '9f3c1a7d2b48e650c1d9a3f7b2e84c60',
   '458b76b95956a33ba7f8aa231d8aee5599ff1ea4daf1242d66083a5d2a1478f5',
   '2024-01-15T00:00:00Z', '2025-01-15T00:00:00Z'),

  ('fp_002_def', 'public', 'documents', 'price_list_2024.pdf', '',
   '4b7e9f2a1c6d8b3e5a0f7c2d9b4e6a18',                 -- password: price2024!
   '6bc5962d134d2d5a9d1fce7efdb3300e920e5185125a76495cdfb677d941aea2',
   '2024-02-01T00:00:00Z', '2025-02-01T00:00:00Z'),

  ('fp_003_ghi', 'public', 'templates', 'contract_template.docx', '',
   'e2d5b8c1f4a7903625ce8b1d4f7a9c30',                 -- password: tmpl2024!
   'dc620bfeabfec436fb4aefda789bab8f5b489874538241141f451b523b45e735',
   '2024-03-10T00:00:00Z', '2025-03-10T00:00:00Z'),

  ('fp_004_jkl', 'private', 'sales', 'manila_q1_report.xlsx', '',
   '7a1f4c9e2b6d8035f9c2a7e4b1d6f8a5',                 -- password: q1manila2024!
   '9f7543cb61cbf98586430351a9ce39321706f77a8cfd20159143f47c92bb5aaf',
   '2024-04-05T00:00:00Z', '2024-10-05T00:00:00Z'),

  ('fp_005_mno', 'private', 'art', 'banner_ldi_2024.psd', '',
   'c9b2e5f8a1d4703c6e9b2f5a8d1c4e70',                 -- password: artpass2024!
   '99340ac9b425be23c0c9241b9f9a3d4d3b883c2c43e44b897b1dc37e6d59eacf',
   '2024-05-20T00:00:00Z', '2025-05-20T00:00:00Z')
on conflict (id) do nothing;


-- ============================================================================
--  6. SEQUENCE SYNC + SCHEMA CACHE RELOAD
-- ============================================================================
--  The sample rows use explicit ids, so move the bigserial counters past them
--  (otherwise the next insert retries id 1 and fails).
select setval(pg_get_serial_sequence('public.users', 'id'),
              coalesce((select max(id) from public.users), 1));
select setval(pg_get_serial_sequence('public.hero_buttons', 'id'),
              coalesce((select max(id) from public.hero_buttons), 1));

-- folder_limits ships empty - an example row to start from:
-- insert into public.folder_limits (bucket, folder, limit_bytes, note)
-- values ('department', 'mis', 5368709120, 'MIS department shared drive')
-- on conflict (bucket, folder) do nothing;

-- Ask PostgREST (Supabase REST API) to pick up the new tables right away.
notify pgrst, 'reload schema';




