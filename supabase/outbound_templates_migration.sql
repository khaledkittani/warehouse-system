-- =====================================================================
-- قوالب الإخراج + فصل المواد + تنفيذ الإخراج (Migration إضافي وآمن)
--
-- يُنفَّذ بعد outbound_requests_migration.sql. مبدأ التصميم: إضافة فقط (additive):
--   • لا يحذف ولا يعدّل أي بيانات: لا المخزون (wms_state)، ولا الاستلامات، ولا حركات الإخراج السابقة،
--     ولا الطلبات القائمة وبنودها وتنفيذاتها. أرصدة المخزون لا تُلمَس إطلاقاً.
--   • الطلبات القديمة تبقى تعمل كما هي بنفس آلية التنفيذ القديمة (لكل بند)؛ لا يُفرَض عليها فصل.
--   • لا توجد عمليات حذف فعلية في هذا الملف: حذف قالب = تعليمه deleted_at، وإزالة مادة من قالب = removed_at.
--   • كل الأوامر idempotent (IF NOT EXISTS / CREATE OR REPLACE) ويمكن إعادة تنفيذ الملف بأمان.
--   • صلاحيات: القوالب/الفصل/التنفيذ لمن يملك can_fulfill (أو المدير) فقط. طالب الإخراج (can_request)
--     لا يستطيع قراءة القوالب ولا مواد التنفيذ (RLS) ولا استدعاء أي دالة منها.
--
-- المفاهيم:
--   outbound_templates            قالب إخراج: مادة مطلوبة (يكتبها المهندس) ← قائمة مواد مستودع
--   outbound_template_components  مواد القالب مع الكمية لكل وحدة
--   outbound_exec_lines           مواد التنفيذ المحفوظة لكل طلب عند الفصل (Snapshot لا يتأثر بتعديل القالب لاحقاً)
--   outbound_exec_runs            سجل عمليات التنفيذ الفعلية (مرتبطة بحركة المخزون)
--   حالة جديدة: split (مفصول — جاهز للتنفيذ)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) حالة جديدة 'split' في قيد حالات الطلب (القيد القديم يُستبدل بنسخة أوسع تقبل كل القيم السابقة)
-- ---------------------------------------------------------------------
do $do$
declare v_name text;
begin
  select c.conname into v_name from pg_constraint c
   where c.conrelid = 'public.outbound_requests'::regclass and c.contype = 'c'
     and pg_get_constraintdef(c.oid) like '%in_progress%' and pg_get_constraintdef(c.oid) not like '%split%'
   limit 1;
  if v_name is not null then
    execute format('alter table public.outbound_requests drop constraint %I', v_name);
  end if;
  if not exists (select 1 from pg_constraint c where c.conrelid = 'public.outbound_requests'::regclass
                   and c.conname = 'outbound_requests_status_check2') then
    alter table public.outbound_requests add constraint outbound_requests_status_check2
      check (status in ('pending','in_progress','partial','completed','cancelled','split'));
  end if;
end $do$;

alter table public.outbound_requests add column if not exists split_at timestamptz;
alter table public.outbound_requests add column if not exists split_by_name text;


-- ---------------------------------------------------------------------
-- 2) الجداول
-- ---------------------------------------------------------------------
create table if not exists public.outbound_templates (
  id              uuid primary key default gen_random_uuid(),
  req_src         text not null check (req_src in ('goods','stock','custom')),   -- نوع المادة المطلوبة (كما في بند الطلب)
  req_key         text not null,                                                  -- مفتاح المادة المطلوبة (نفس material_key في بنود الطلب)
  req_name        text not null,
  active          boolean not null default true,                                  -- تعطيل القالب = لا يُستخدم عند الفصل (دون حذفه)
  note            text,
  created_by      uuid,
  created_by_name text,
  created_at      timestamptz not null default now(),
  updated_by      uuid,
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz                                                      -- حذف منطقي
);
-- قالب واحد فقط لكل مادة مطلوبة (غير محذوف)
create unique index if not exists outbound_templates_req_uq
  on public.outbound_templates (req_src, req_key) where deleted_at is null;

create table if not exists public.outbound_template_components (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid not null references public.outbound_templates(id) on delete restrict,
  mat_src      text not null check (mat_src in ('goods','stock')),               -- مواد المخزون الفعلي فقط
  mat_key      text not null,
  mat_name     text not null,
  qty_per_unit numeric not null check (qty_per_unit > 0),
  sort_no      int not null default 0,
  created_at   timestamptz not null default now(),
  removed_at   timestamptz                                                         -- إزالة منطقية (تعديل القالب لا يمسح التاريخ)
);
create unique index if not exists outbound_tpl_comp_uq
  on public.outbound_template_components (template_id, mat_src, mat_key) where removed_at is null;
create index if not exists outbound_tpl_comp_tpl_idx on public.outbound_template_components (template_id);

create table if not exists public.outbound_exec_lines (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references public.outbound_requests(id) on delete restrict,
  line_no      int not null,
  mat_src      text not null check (mat_src in ('goods','stock','custom')),
  mat_key      text not null,
  mat_name     text not null,
  qty_required numeric not null check (qty_required > 0),
  qty_done     numeric not null default 0 check (qty_done >= 0),
  sources      jsonb not null default '[]'::jsonb,   -- من أي بنود/قوالب جاءت هذه الكمية (Snapshot يوضّح الحساب)
  split_at     timestamptz not null default now(),
  split_by     uuid,
  superseded_at timestamptz,                         -- عند إعادة الفصل قبل أي تنفيذ تُستبدل الأسطر القديمة (تُعلَّم فقط)
  check (qty_done <= qty_required)
);
create index if not exists outbound_exec_lines_req_idx on public.outbound_exec_lines (request_id) where superseded_at is null;

create table if not exists public.outbound_exec_runs (
  id               uuid primary key default gen_random_uuid(),
  request_id       uuid not null references public.outbound_requests(id) on delete restrict,
  line_id          uuid not null references public.outbound_exec_lines(id) on delete restrict,
  qty              numeric not null check (qty > 0),
  executed_by      uuid not null,
  executed_by_name text,
  executed_at      timestamptz not null default now(),
  ledger_ref       text,                              -- معرّف حركة الإخراج في سجل المخزون المرتبطة بهذا الطلب
  note             text,
  voided_at        timestamptz,
  voided_by        uuid
);
create index if not exists outbound_exec_runs_req_idx on public.outbound_exec_runs (request_id, executed_at);


-- ---------------------------------------------------------------------
-- 3) RLS: القراءة لموظف المستودع/المدير فقط (can_fulfill)؛ لا كتابة مباشرة من المتصفح
-- ---------------------------------------------------------------------
alter table public.outbound_templates           enable row level security;
alter table public.outbound_template_components enable row level security;
alter table public.outbound_exec_lines          enable row level security;
alter table public.outbound_exec_runs           enable row level security;

do $do$
begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='outbound_templates' and policyname='outbound_templates_select') then
    create policy outbound_templates_select on public.outbound_templates for select to authenticated using (public.can_fulfill());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='outbound_template_components' and policyname='outbound_tpl_comp_select') then
    create policy outbound_tpl_comp_select on public.outbound_template_components for select to authenticated using (public.can_fulfill());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='outbound_exec_lines' and policyname='outbound_exec_lines_select') then
    create policy outbound_exec_lines_select on public.outbound_exec_lines for select to authenticated using (public.can_fulfill());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='outbound_exec_runs' and policyname='outbound_exec_runs_select') then
    create policy outbound_exec_runs_select on public.outbound_exec_runs for select to authenticated using (public.can_fulfill());
  end if;
end $do$;

revoke all on public.outbound_templates, public.outbound_template_components,
              public.outbound_exec_lines, public.outbound_exec_runs from anon, authenticated;
grant select on public.outbound_templates, public.outbound_template_components,
                public.outbound_exec_lines, public.outbound_exec_runs to authenticated;


-- ---------------------------------------------------------------------
-- 4) إنشاء/تعديل قالب (مع مواده) — ذرّي. المواد القديمة غير الموجودة في القائمة الجديدة تُعلَّم removed_at.
-- ---------------------------------------------------------------------
create or replace function public.outbound_save_template(
  p_id uuid, p_req_src text, p_req_key text, p_req_name text,
  p_active boolean, p_note text, p_components jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_name text; v_id uuid := p_id; v_c jsonb; v_n int := 0; v_qty numeric;
  v_src text; v_key text; v_mname text; v_exist public.outbound_templates; v_keep uuid[] := '{}'; v_cid uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if not public.can_fulfill() then raise exception 'forbidden: fulfill permission required'; end if;
  if coalesce(p_req_src,'') not in ('goods','stock','custom') then raise exception 'invalid material_src'; end if;
  if nullif(trim(coalesce(p_req_key,'')),'') is null or nullif(trim(coalesce(p_req_name,'')),'') is null then raise exception 'material required'; end if;
  if p_req_src = 'custom' and not exists (select 1 from public.outbound_custom_materials c where c.name_key = trim(p_req_key)) then
    raise exception 'unknown custom material';
  end if;
  if p_components is null or jsonb_typeof(p_components) <> 'array' or jsonb_array_length(p_components) = 0 then
    raise exception 'template needs at least one component';
  end if;
  if jsonb_array_length(p_components) > 100 then raise exception 'too many components (max 100)'; end if;

  -- تحقق من المواد قبل أي كتابة
  for v_c in select * from jsonb_array_elements(p_components) loop
    v_src := v_c->>'mat_src'; v_key := nullif(trim(coalesce(v_c->>'mat_key','')),''); v_mname := nullif(trim(coalesce(v_c->>'mat_name','')),'');
    if coalesce(v_src,'') not in ('goods','stock') then raise exception 'invalid component source'; end if;
    if v_key is null or v_mname is null then raise exception 'component material required'; end if;
    begin v_qty := (v_c->>'qty_per_unit')::numeric; exception when others then raise exception 'invalid qty'; end;
    if v_qty is null or v_qty <= 0 or v_qty > 1000000 then raise exception 'invalid qty'; end if;
  end loop;
  if (select count(*) from (select distinct v->>'mat_src', trim(v->>'mat_key') from jsonb_array_elements(p_components) v) d)
     <> jsonb_array_length(p_components) then
    raise exception 'duplicate component';
  end if;

  v_name := coalesce(
    (select nullif(trim(p.display_name), '') from public.wms_user_perms p where p.user_id = v_uid),
    nullif(split_part(coalesce(auth.jwt()->>'email',''), '@', 1), ''), 'مستخدم');

  select * into v_exist from public.outbound_templates
   where req_src = p_req_src and req_key = trim(p_req_key) and deleted_at is null;

  if v_id is null then
    if found then raise exception 'template already exists for this material'; end if;
    insert into public.outbound_templates (req_src, req_key, req_name, active, note, created_by, created_by_name, updated_by)
      values (p_req_src, trim(p_req_key), left(trim(p_req_name),200), coalesce(p_active,true),
              nullif(left(trim(coalesce(p_note,'')),500),''), v_uid, v_name, v_uid)
      returning id into v_id;
  else
    perform 1 from public.outbound_templates where id = v_id and deleted_at is null for update;
    if not found then raise exception 'template not found'; end if;
    if v_exist.id is not null and v_exist.id <> v_id then raise exception 'template already exists for this material'; end if;
    update public.outbound_templates
       set req_src = p_req_src, req_key = trim(p_req_key), req_name = left(trim(p_req_name),200),
           active = coalesce(p_active, active), note = nullif(left(trim(coalesce(p_note,'')),500),''),
           updated_by = v_uid, updated_at = now()
     where id = v_id;
  end if;

  for v_c in select * from jsonb_array_elements(p_components) loop
    v_n := v_n + 1;
    select id into v_cid from public.outbound_template_components
     where template_id = v_id and mat_src = v_c->>'mat_src' and mat_key = trim(v_c->>'mat_key') and removed_at is null;
    if found then
      update public.outbound_template_components
         set qty_per_unit = (v_c->>'qty_per_unit')::numeric, mat_name = left(trim(v_c->>'mat_name'),200), sort_no = v_n
       where id = v_cid;
    else
      insert into public.outbound_template_components (template_id, mat_src, mat_key, mat_name, qty_per_unit, sort_no)
        values (v_id, v_c->>'mat_src', trim(v_c->>'mat_key'), left(trim(v_c->>'mat_name'),200), (v_c->>'qty_per_unit')::numeric, v_n)
        returning id into v_cid;
    end if;
    v_keep := v_keep || v_cid;
  end loop;
  update public.outbound_template_components set removed_at = now()
   where template_id = v_id and removed_at is null and not (id = any(v_keep));

  return jsonb_build_object('id', v_id, 'components', v_n);
end;
$$;

-- تفعيل/تعطيل/حذف (منطقي) قالب
create or replace function public.outbound_set_template_state(p_id uuid, p_action text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.can_fulfill() then raise exception 'forbidden: fulfill permission required'; end if;
  if p_action not in ('enable','disable','remove') then raise exception 'unsupported action'; end if;
  perform 1 from public.outbound_templates where id = p_id and deleted_at is null for update;
  if not found then raise exception 'template not found'; end if;
  if p_action = 'remove' then
    update public.outbound_templates set deleted_at = now(), active = false, updated_by = auth.uid(), updated_at = now() where id = p_id;
  else
    update public.outbound_templates set active = (p_action = 'enable'), updated_by = auth.uid(), updated_at = now() where id = p_id;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;


-- ---------------------------------------------------------------------
-- 5) فصل مواد الطلب: لكل بند ← القالب الفعّال لمادته (يتضاعف بالكمية) أو يبقى مباشراً كما طُلب،
--    ثم دمج المواد المتكررة في سطر واحد. p_commit=false = معاينة فقط (لا كتابة إطلاقاً).
--    الفصل لا يخصم أي شيء من المخزون ولا يغيّر بنود طلب المهندس.
--    p_links: ربط بنود "بدون قالب" بمادة مخزون فعلية: {"<item_id>":{"src":"goods|stock","key":"..","name":".."}}
-- ---------------------------------------------------------------------
create or replace function public.outbound_split_request(
  p_request_id uuid, p_links jsonb default '{}'::jsonb, p_commit boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_req public.outbound_requests; v_item public.outbound_request_items;
  v_tpl public.outbound_templates; v_comp public.outbound_template_components;
  v_atoms jsonb := '[]'::jsonb; v_ord int := 0; v_link jsonb; v_lines jsonb; v_items jsonb := '[]'::jsonb;
  v_name text; v_kind text; v_src text; v_key text; v_mname text; v_n int := 0; v_row record;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if not public.can_fulfill() then raise exception 'forbidden: fulfill permission required'; end if;
  if p_links is null or jsonb_typeof(p_links) <> 'object' then p_links := '{}'::jsonb; end if;

  if p_commit then
    select * into v_req from public.outbound_requests where id = p_request_id for update;
  else
    select * into v_req from public.outbound_requests where id = p_request_id;
  end if;
  if not found then raise exception 'request not found'; end if;
  if v_req.status not in ('pending','in_progress','split') then raise exception 'request cannot be split (status=%)', v_req.status; end if;
  if exists (select 1 from public.outbound_executions e where e.request_id = p_request_id and e.voided_at is null)
     or exists (select 1 from public.outbound_exec_runs r where r.request_id = p_request_id and r.voided_at is null) then
    raise exception 'request already has executions';
  end if;

  for v_item in select * from public.outbound_request_items where request_id = p_request_id order by line_no loop
    select * into v_tpl from public.outbound_templates
     where req_src = v_item.material_src and req_key = v_item.material_key and deleted_at is null and active;
    if found then
      v_items := v_items || jsonb_build_object('item_id', v_item.id, 'kind', 'template', 'template_id', v_tpl.id);
      for v_comp in select * from public.outbound_template_components
                     where template_id = v_tpl.id and removed_at is null order by sort_no, created_at loop
        v_ord := v_ord + 1;
        v_atoms := v_atoms || jsonb_build_object('ord', v_ord, 'mat_src', v_comp.mat_src, 'mat_key', v_comp.mat_key,
          'mat_name', v_comp.mat_name, 'qty', v_item.qty_requested * v_comp.qty_per_unit,
          'src', jsonb_build_object('item_id', v_item.id, 'item_name', v_item.material_name, 'item_qty', v_item.qty_requested,
                                    'kind', 'template', 'template_id', v_tpl.id, 'per_unit', v_comp.qty_per_unit,
                                    'qty', v_item.qty_requested * v_comp.qty_per_unit, 'site', v_item.site, 'recipient', v_item.recipient));
      end loop;
    else
      v_link := p_links -> (v_item.id::text);
      v_kind := 'direct'; v_src := v_item.material_src; v_key := v_item.material_key; v_mname := v_item.material_name;
      if v_link is not null and jsonb_typeof(v_link) = 'object' and (v_link->>'src') in ('goods','stock')
         and nullif(trim(coalesce(v_link->>'key','')),'') is not null then
        v_kind := 'linked'; v_src := v_link->>'src'; v_key := trim(v_link->>'key');
        v_mname := coalesce(nullif(trim(v_link->>'name'),''), v_item.material_name);
      end if;
      v_items := v_items || jsonb_build_object('item_id', v_item.id, 'kind', v_kind);
      v_ord := v_ord + 1;
      v_atoms := v_atoms || jsonb_build_object('ord', v_ord, 'mat_src', v_src, 'mat_key', v_key, 'mat_name', v_mname,
        'qty', v_item.qty_requested,
        'src', jsonb_build_object('item_id', v_item.id, 'item_name', v_item.material_name, 'item_qty', v_item.qty_requested,
                                  'kind', v_kind, 'qty', v_item.qty_requested, 'site', v_item.site, 'recipient', v_item.recipient));
    end if;
  end loop;

  -- دمج المواد المتكررة (نفس المادة من أكثر من بند/مكوّن) في سطر واحد بمجموع الكميات
  select coalesce(jsonb_agg(jsonb_build_object('mat_src', g.mat_src, 'mat_key', g.mat_key, 'mat_name', g.mat_name,
                                               'qty_required', g.qty, 'sources', g.srcs) order by g.first_ord), '[]'::jsonb)
    into v_lines
    from (
      select a.mat_src, a.mat_key, (array_agg(a.mat_name order by a.ord))[1] as mat_name, sum(a.qty) as qty,
             jsonb_agg(a.src order by a.ord) as srcs, min(a.ord) as first_ord
        from jsonb_to_recordset(v_atoms) as a(ord int, mat_src text, mat_key text, mat_name text, qty numeric, src jsonb)
       group by a.mat_src, a.mat_key
    ) g;

  if not p_commit then
    return jsonb_build_object('committed', false, 'lines', v_lines, 'items', v_items);
  end if;

  update public.outbound_exec_lines set superseded_at = now() where request_id = p_request_id and superseded_at is null;
  for v_row in select * from jsonb_to_recordset(v_lines) as x(mat_src text, mat_key text, mat_name text, qty_required numeric, sources jsonb) loop
    v_n := v_n + 1;
    insert into public.outbound_exec_lines (request_id, line_no, mat_src, mat_key, mat_name, qty_required, sources, split_by)
      values (p_request_id, v_n, v_row.mat_src, v_row.mat_key, v_row.mat_name, v_row.qty_required, v_row.sources, v_uid);
  end loop;
  v_name := coalesce(
    (select nullif(trim(p.display_name), '') from public.wms_user_perms p where p.user_id = v_uid),
    nullif(split_part(coalesce(auth.jwt()->>'email',''), '@', 1), ''), 'مستخدم');
  update public.outbound_requests set status = 'split', split_at = now(), split_by_name = v_name, updated_at = now()
   where id = p_request_id;
  return jsonb_build_object('committed', true, 'lines', v_lines, 'items', v_items, 'status', 'split');
end;
$$;


-- ---------------------------------------------------------------------
-- 6) إعادة حساب المنجَز في بنود طلب المهندس من تقدّم مواد التنفيذ (يحافظ على عرض "تم/المتبقي" في القائمة).
--    نسبة إنجاز البند = أقل نسبة إنجاز بين أسطر التنفيذ التي ساهم فيها (محافِظة).
-- ---------------------------------------------------------------------
create or replace function public.outbound_recalc_items(p_request_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.outbound_request_items i
     set qty_done = case
       when f.frac >= 1 then i.qty_requested
       else least(i.qty_requested, round(i.qty_requested * f.frac, 3)) end
    from (
      select it.id as item_id, coalesce((
        select min(least(1, l.qty_done / l.qty_required))
          from public.outbound_exec_lines l, jsonb_array_elements(l.sources) s
         where l.request_id = it.request_id and l.superseded_at is null and (s->>'item_id')::uuid = it.id), 0) as frac
        from public.outbound_request_items it where it.request_id = p_request_id
    ) f
   where i.id = f.item_id;
end;
$$;
revoke all on function public.outbound_recalc_items(uuid) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 7) تسجيل تنفيذ كمية لسطر من مواد التنفيذ (يُستدعى بعد تسجيل حركة الإخراج في مخزون النظام الحالي)
-- ---------------------------------------------------------------------
create or replace function public.outbound_record_line_execution(
  p_line_id uuid, p_qty numeric, p_ledger_ref text default null, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_line public.outbound_exec_lines; v_req public.outbound_requests;
  v_all boolean; v_status text; v_name text; v_run uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if not public.can_fulfill() then raise exception 'forbidden: fulfill permission required'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'invalid qty'; end if;

  select * into v_line from public.outbound_exec_lines where id = p_line_id for update;
  if not found then raise exception 'line not found'; end if;
  if v_line.superseded_at is not null then raise exception 'line superseded'; end if;
  select * into v_req from public.outbound_requests where id = v_line.request_id for update;
  if v_req.status not in ('split','partial') then raise exception 'request is %', v_req.status; end if;
  if v_line.qty_done + p_qty > v_line.qty_required then
    raise exception 'qty exceeds remaining (remaining=%)', (v_line.qty_required - v_line.qty_done);
  end if;

  v_name := coalesce(
    (select nullif(trim(p.display_name), '') from public.wms_user_perms p where p.user_id = v_uid),
    nullif(split_part(coalesce(auth.jwt()->>'email',''), '@', 1), ''), 'مستخدم');

  update public.outbound_exec_lines set qty_done = qty_done + p_qty where id = p_line_id;
  insert into public.outbound_exec_runs (request_id, line_id, qty, executed_by, executed_by_name, ledger_ref, note)
    values (v_line.request_id, p_line_id, p_qty, v_uid, v_name, p_ledger_ref, nullif(left(trim(coalesce(p_note,'')),500),''))
    returning id into v_run;

  select bool_and(qty_done >= qty_required) into v_all
    from public.outbound_exec_lines where request_id = v_line.request_id and superseded_at is null;
  v_status := case when v_all then 'completed' else 'partial' end;
  update public.outbound_requests set status = v_status, updated_at = now() where id = v_line.request_id;
  perform public.outbound_recalc_items(v_line.request_id);

  return jsonb_build_object('run_id', v_run, 'request_status', v_status,
                            'line_done', v_line.qty_done + p_qty, 'line_remaining', v_line.qty_required - v_line.qty_done - p_qty);
end;
$$;

-- تراجع عن تسجيل تنفيذ سطر (تعويض تلقائي فقط إذا فشل تسجيل حركة المخزون؛ لا يحذف شيئاً)
create or replace function public.outbound_undo_line_execution(p_run_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_r public.outbound_exec_runs; v_any boolean; v_status text; v_cur text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.can_fulfill() then raise exception 'forbidden: fulfill permission required'; end if;
  select * into v_r from public.outbound_exec_runs where id = p_run_id for update;
  if not found then raise exception 'execution not found'; end if;
  if v_r.voided_at is not null then raise exception 'execution already voided'; end if;
  if v_r.executed_by <> auth.uid() and not public.is_admin() then raise exception 'forbidden'; end if;
  if v_r.executed_at < now() - interval '10 minutes' then raise exception 'too old to undo'; end if;
  update public.outbound_exec_lines set qty_done = greatest(0, qty_done - v_r.qty) where id = v_r.line_id;
  update public.outbound_exec_runs set voided_at = now(), voided_by = auth.uid() where id = p_run_id;
  select status into v_cur from public.outbound_requests where id = v_r.request_id for update;
  select bool_or(qty_done > 0) into v_any from public.outbound_exec_lines where request_id = v_r.request_id and superseded_at is null;
  v_status := case when v_any then 'partial' when v_cur in ('completed','partial') then 'split' else v_cur end;
  update public.outbound_requests set status = v_status, updated_at = now() where id = v_r.request_id;
  perform public.outbound_recalc_items(v_r.request_id);
  return jsonb_build_object('request_status', v_status);
end;
$$;


-- ---------------------------------------------------------------------
-- 8) حارس على آلية التنفيذ القديمة (لكل بند): لا تُستخدم على طلب تم فصله (حتى لا يتكرر الخصم)
--    كل شيء آخر في الدالة كما هو دون تغيير.
-- ---------------------------------------------------------------------
create or replace function public.outbound_record_execution(
  p_item_id uuid, p_qty numeric, p_ledger_ref text default null, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_item public.outbound_request_items; v_req public.outbound_requests;
  v_all boolean; v_any boolean; v_status text; v_name text; v_exec uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if not public.can_fulfill() then raise exception 'forbidden: fulfill permission required'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'invalid qty'; end if;

  select * into v_item from public.outbound_request_items where id = p_item_id for update;
  if not found then raise exception 'item not found'; end if;
  select * into v_req from public.outbound_requests where id = v_item.request_id for update;
  if v_req.status in ('completed','cancelled') then raise exception 'request is %', v_req.status; end if;
  if exists (select 1 from public.outbound_exec_lines l where l.request_id = v_item.request_id and l.superseded_at is null) then
    raise exception 'request is split: execute the split materials';
  end if;
  if v_item.qty_done + p_qty > v_item.qty_requested then
    raise exception 'qty exceeds remaining (remaining=%)', (v_item.qty_requested - v_item.qty_done);
  end if;

  v_name := coalesce(
    (select nullif(trim(p.display_name), '') from public.wms_user_perms p where p.user_id = v_uid),
    nullif(split_part(coalesce(auth.jwt()->>'email',''), '@', 1), ''), 'مستخدم');

  update public.outbound_request_items set qty_done = qty_done + p_qty where id = p_item_id;
  insert into public.outbound_executions (request_id, item_id, qty, executed_by, executed_by_name, ledger_ref, note)
    values (v_item.request_id, p_item_id, p_qty, v_uid, v_name, p_ledger_ref, nullif(left(trim(coalesce(p_note,'')),500),''))
    returning id into v_exec;

  select bool_and(qty_done >= qty_requested), bool_or(qty_done > 0) into v_all, v_any
    from public.outbound_request_items where request_id = v_item.request_id;
  v_status := case when v_all then 'completed' when v_any then 'partial' else v_req.status end;
  update public.outbound_requests set status = v_status, updated_at = now() where id = v_item.request_id;

  return jsonb_build_object('execution_id', v_exec, 'request_status', v_status,
                            'item_done', v_item.qty_done + p_qty,
                            'item_remaining', v_item.qty_requested - v_item.qty_done - p_qty);
end;
$$;


-- ---------------------------------------------------------------------
-- 9) صلاحيات تنفيذ الدوال: المستخدمون المسجّلون فقط (والتحقق من can_fulfill داخل كل دالة)
-- ---------------------------------------------------------------------
revoke all on function public.outbound_save_template(uuid, text, text, text, boolean, text, jsonb) from public;
revoke all on function public.outbound_set_template_state(uuid, text)                   from public;
revoke all on function public.outbound_split_request(uuid, jsonb, boolean)              from public;
revoke all on function public.outbound_record_line_execution(uuid, numeric, text, text) from public;
revoke all on function public.outbound_undo_line_execution(uuid)                        from public;
revoke execute on function public.outbound_save_template(uuid, text, text, text, boolean, text, jsonb),
  public.outbound_set_template_state(uuid, text), public.outbound_split_request(uuid, jsonb, boolean),
  public.outbound_record_line_execution(uuid, numeric, text, text), public.outbound_undo_line_execution(uuid) from anon;
grant execute on function public.outbound_save_template(uuid, text, text, text, boolean, text, jsonb) to authenticated;
grant execute on function public.outbound_set_template_state(uuid, text)                   to authenticated;
grant execute on function public.outbound_split_request(uuid, jsonb, boolean)              to authenticated;
grant execute on function public.outbound_record_line_execution(uuid, numeric, text, text) to authenticated;
grant execute on function public.outbound_undo_line_execution(uuid)                        to authenticated;
