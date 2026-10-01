-- ============================================================================
--  reset_db.sql
--  LDI Sales Dashboard - Supabase (PostgreSQL) FULL RESET
-- ============================================================================
--  Burahin lahat ng data at tables, saka gawin ulit ang buong schema
--  (structure + seed data) na gamit ng index.html, dashboard.html,
--  mis.html at settings/*.html
--
--  HOW TO RUN
--  ----------
--    Supabase Studio : SQL Editor -> New query -> paste -> Run
--    psql           : psql "$SUPABASE_DB_URL" -f reset_db.sql
--
--  WARNING: permanent ang pagkasira ng data. Walang undo.
--  I-backup muna kung may itatago (Table Editor -> Export CSV, o pg_dump).
--
--  Safe to run more than once (idempotent).
-- ============================================================================


-- ============================================================================
--  1. DROP  (una ito)
-- ============================================================================
drop table if exists public.file_passwords   cascade;
drop table if exists public.shared_items     cascade;
drop table if exists public.shared_org_items cascade;
drop table if exists public.folder_limits    cascade;
drop table if exists public.sidebar_buttons  cascade;
drop table if exists public.hero_buttons     cascade;
drop table if exists public.users            cascade;


-- ============================================================================
--  2. EXTENSIONS
-- ============================================================================
create extension if not exists pgcrypto;


-- ============================================================================
--  3. TABLES
-- ============================================================================

-- Login accounts: index.html (login), dashboard.html, settings/user-setting.html
create table if not exists public.users (
  id                        bigserial   primary key,
  username                  text        not null unique,
  password                  text        not null default '',
  full_name                 text        not null default '',
  contact                   bigint,
  email                     text        not null default '',
  role                      text        not null default 'user',     -- superadmin | admin | user
  status                    text        not null default 'pending',  -- active | inactive | pending
  allowed_hero_buttons      jsonb       not null default '[]'::jsonb,
  assigned_companies        jsonb       not null default '[]'::jsonb,
  assigned_sales_rep_codes  jsonb       not null default '[]'::jsonb,
  assigned_areas            jsonb       not null default '[]'::jsonb,
  approver                  jsonb       not null default '[]'::jsonb,
  department                text        not null default '',
  position                  text        not null default '',
  created_at                timestamptz not null default now()
);

create table if not exists public.hero_buttons (
  id          bigserial primary key,
  label       text      not null,
  href        text      not null default '#',
  sort_order  integer   not null default 0
);

create table if not exists public.sidebar_buttons (
  id          text      primary key,
  bucket      text      not null default 'department',
  folder      text      not null default '/',
  sort_order  integer   not null default 0,
  icon        text      not null default U&'\D83D\DCC1',
  label       text      not null default 'Untitled',
  link        text      not null default '',
  roles       jsonb     not null default '[]'::jsonb
);

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

-- password_hash = sha256(salt + '|' + password) as hexadecimal
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

create table if not exists public.folder_limits (
  id          bigserial primary key,
  bucket      text not null default 'department',
  folder      text not null,
  limit_bytes bigint,
  note        text default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ------------------------------------------------------ shared_org_items ----
--  Organisasyon ng "Shared with me" (corplan2.html): bawat row ay isang
--  entry sa loob ng virtual folder tree. kind 'item' = shared_items row,
--  kind 'folder' = virtual folder lamang (shared_item_id = null).
--  sort_order = bigint dahil gumagamit ng Date.now() (~1.7e12).
create table if not exists public.shared_org_items (
  id              text        primary key,
  user_id         text        not null default '',
  kind            text        not null default 'item',   -- item | folder
  shared_item_id  text,                                 -- null kapag folder
  abs_bucket      text,                                 -- null kapag folder
  abs_folder      text,                                 -- null kapag folder
  abs_path        text,                                 -- null kapag folder
  name            text        not null default '',
  is_folder       boolean     not null default false,
  display_name    text,                                 -- rename ng user
  hidden          boolean     not null default false,
  virtual_path    text        not null default '',      -- 'parent/child/'
  sort_order      bigint      not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);


-- ============================================================================
--  4. INDEXES
-- ============================================================================
create index if not exists hero_buttons_sort_idx
  on public.hero_buttons (sort_order, id);

create index if not exists sidebar_buttons_lookup_idx
  on public.sidebar_buttons (bucket, folder, sort_order);

create index if not exists shared_items_lookup_idx
  on public.shared_items (bucket, folder, path);

create unique index if not exists file_passwords_lookup_key
  on public.file_passwords (bucket, folder, path);

create unique index if not exists folder_limits_bucket_folder_key
  on public.folder_limits (bucket, folder);

-- shared_org_items: corplan2.html laging .eq('user_id', uid), tapos
-- nagfi-filter ngayon ng virtual_path
create index if not exists shared_org_items_user_vpath_idx
  on public.shared_org_items (user_id, virtual_path);



-- ============================================================================
--  5. ROW LEVEL SECURITY + POLICIES
--  Wide open (true) - gaya ng dati. I-tighten bago production.
-- ============================================================================
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
create policy "file_passwords update" on public.file_passwords for update with check (true);
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

alter table public.shared_org_items enable row level security;

drop policy if exists "shared_org_items read"   on public.shared_org_items;
drop policy if exists "shared_org_items insert" on public.shared_org_items;
drop policy if exists "shared_org_items update" on public.shared_org_items;
drop policy if exists "shared_org_items delete" on public.shared_org_items;

create policy "shared_org_items read"   on public.shared_org_items for select using (true);
create policy "shared_org_items insert" on public.shared_org_items for insert with check (true);
create policy "shared_org_items update" on public.shared_org_items for update using (true);
create policy "shared_org_items delete" on public.shared_org_items for delete using (true);


-- ============================================================================
--  6. GRANTS
-- ============================================================================
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
    'shared_items', 'file_passwords', 'folder_limits',
    'shared_org_items'
  ]
  loop
    execute format('grant select, insert, update, delete on public.%I to %s', tbl, role_list);
  end loop;

  execute format('grant usage, select on all sequences in schema public to %s', role_list);
end $$;


-- ============================================================================
--  7. SEED DATA  (mula sa dating CSV / sample_db.sql)
--  Burahin ang block na ito kung gusto mong simulan ng walang sample rows.
-- ============================================================================

-- ------------------------------------------------------------------ users ---
--  allowed_hero_buttons: ["all"] = lahat, otherwise hero_buttons id/label
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

-- ---------------------------------------------------------- hero_buttons ---
insert into public.hero_buttons (id, label, href, sort_order) values
  (1, 'Sales Dashboard', '/dashboard', 1),
  (2, 'Inventory',       '/inventory', 2),
  (3, 'ART Files',       '/art',       3),
  (4, 'Reports',         '/reports',   4),
  (5, 'Settings',        '/settings',  5)
on conflict (id) do nothing;

-- -------------------------------------------------------- sidebar_buttons ---
insert into public.sidebar_buttons (id, bucket, folder, sort_order, label, link, roles) values
  ('1', 'public', '/',         1, 'Home',            '/',          '["admin","manager","sales_rep"]'::jsonb),
  ('2', 'public', 'dashboard', 2, 'Dashboard',       '/dashboard', '["admin","manager","sales_rep"]'::jsonb),
  ('3', 'public', 'art',       3, 'ART Gallery',     '/art',       '["admin","manager","sales_rep","art_editor"]'::jsonb),
  ('4', 'public', 'files',     4, 'File Manager',    '/files',     '["admin","manager"]'::jsonb),
  ('5', 'public', 'inventory', 5, 'Inventory',       '/inventory', '["admin","manager","sales_rep"]'::jsonb),
  ('6', 'public', 'reports',   6, 'Reports',         '/reports',   '["admin","manager"]'::jsonb),
  ('7', 'public', 'users',     7, 'User Management', '/users',     '["admin","manager"]'::jsonb)
on conflict (id) do nothing;



-- ----------------------------------------------------------- shared_items ---
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

-- --------------------------------------------------------- file_passwords ---
--  password_hash = sha256(password_salt || '|' || password)
--    fp_001_abc = ldi2024!        fp_002_def = price2024!
--    fp_003_ghi = tmpl2024!       fp_004_jkl = q1manila2024!
--    fp_005_mno = artpass2024!
insert into public.file_passwords
  (id, bucket, folder, path, owner_id, password_salt, password_hash,
   created_at, expires_at)
values
  ('fp_001_abc', 'public', 'images', 'logo.gif', '',
   '9f3c1a7d2b48e650c1d9a3f7b2e84c60',
   '458b76b95956a33ba7f8aa231d8aee5599ff1ea4daf1242d66083a5d2a1478f5',
   '2024-01-15T00:00:00Z', '2025-01-15T00:00:00Z'),

  ('fp_002_def', 'public', 'documents', 'price_list_2024.pdf', '',
   '4b7e9f2a1c6d8b3e5a0f7c2d9b4e6a18',
   '6bc5962d134d2d5a9d1fce7efdb3300e920e5185125a76495cdfb677d941aea2',
   '2024-02-01T00:00:00Z', '2025-02-01T00:00:00Z'),

  ('fp_003_ghi', 'public', 'templates', 'contract_template.docx', '',
   'e2d5b8c1f4a7903625ce8b1d4f7a9c30',
   'dc620bfeabfec436fb4aefda789bab8f5b489874538241141f451b523b45e735',
   '2024-03-10T00:00:00Z', '2025-03-10T00:00:00Z'),

  ('fp_004_jkl', 'private', 'sales', 'manila_q1_report.xlsx', '',
   '7a1f4c9e2b6d8035f9c2a7e4b1d6f8a5',
   '9f7543cb61cbf98586430351a9ce39321706f77a8cfd20159143f47c92bb5aaf',
   '2024-04-05T00:00:00Z', '2024-10-05T00:00:00Z'),

  ('fp_005_mno', 'private', 'art', 'banner_ldi_2024.psd', '',
   'c9b2e5f8a1d4703c6e9b2f5a8d1c4e70',
   '99340ac9b425be23c0c9241b9f9a3d4d3b883c2c43e44b897b1dc37e6d59eacf',
   '2024-05-20T00:00:00Z', '2025-05-20T00:00:00Z')
on conflict (id) do nothing;

-- folder_limits: walang default row. Halimbawa:
-- insert into public.folder_limits (bucket, folder, limit_bytes, note)
-- values ('department', 'mis', 5368709120, 'MIS department shared drive')
-- on conflict (bucket, folder) do nothing;


-- ============================================================================
--  8. SEQUENCE SYNC + SCHEMA RELOAD
--  Kailangan para hindi maulit ang id 1 sa susunod na insert.
-- ============================================================================
select setval(pg_get_serial_sequence('public.users', 'id'),
              coalesce((select max(id) from public.users), 1));
select setval(pg_get_serial_sequence('public.hero_buttons', 'id'),
              coalesce((select max(id) from public.hero_buttons), 1));

-- Para magingkabit agad ang PostgREST (Supabase REST API) sa bagong tables.
notify pgrst, 'reload schema';

