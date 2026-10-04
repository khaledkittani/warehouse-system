-- =====================================================================
-- طلبات إخراج البضاعة (Outbound Requests) — Migration إضافي وآمن
--
-- مبدأ التصميم: إضافة فقط (additive). لا يحذف ولا يعدّل أي جدول/بيانات/سياسة موجودة:
--   • لا لمس لـ profiles ولا لأدوارها (admin / viewer) — الصلاحيات الجديدة في جدول مستقل wms_user_perms.
--   • لا لمس لـ wms_state ولا لسياساته الحالية (admin) — فقط تُضاف سياسة إضافية (permissive) تسمح
--     لمن لديه can_fulfill بكتابة 4 مفاتيح مخزون محددة فقط (انظر القسم 8 للتفاصيل والمقايضة).
--   • كل الأوامر idempotent (IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF EXISTS ثم CREATE).
--
-- لا يُنفَّذ تلقائياً من أي جلسة: انسخه إلى Supabase SQL Editor بعد المراجعة والموافقة
-- (حسب قواعد المشروع: أي تعديل على المخطط/RLS يتطلب موافقة صريحة).
--
-- يعتمد على جدولي profiles و wms_state الموجودين في المشروع (الدالة is_admin() تُنشأ في القسم 0 إن لم تكن موجودة).
--
-- بعد التنفيذ: امنح الصلاحيات للمستخدمين يدوياً (القسم 10 في آخر الملف).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0) is_admin() — تُنشأ هنا لأن مشروع Supabase الحي لا يحتويها (كانت في ملف المخطط المقترح فقط).
--    لا تغيّر أي شيء موجود: الدالة جديدة، تقرأ profiles.role فقط.
-- ---------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin');
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;


-- ---------------------------------------------------------------------
-- 1) wms_user_perms — صلاحيات طلبات الإخراج (مستقلة عن profiles.role)
--    can_request : يستطيع إنشاء طلبات إخراج ومتابعة طلباته (مثل حساب "أبو أيوب")
--    can_fulfill : موظف مستودع — يرى كل الطلبات وينفّذها ويحدّث حالتها
--    admin (profiles.role='admin') يملك الاثنين ضمنياً.
--    لا توجد أي سياسة كتابة من المتصفح: المنح يدوي من لوحة Supabase فقط (لا تصعيد ذاتي للصلاحيات).
-- ---------------------------------------------------------------------
create table if not exists public.wms_user_perms (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  can_request  boolean not null default false,
  can_fulfill  boolean not null default false,
  created_at   timestamptz not null default now()
);
alter table public.wms_user_perms enable row level security;

drop policy if exists wms_user_perms_select_own_or_admin on public.wms_user_perms;
create policy wms_user_perms_select_own_or_admin
  on public.wms_user_perms for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

create or replace function public.can_request()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from public.wms_user_perms p where p.user_id = auth.uid() and p.can_request
  );
$$;
create or replace function public.can_fulfill()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from public.wms_user_perms p where p.user_id = auth.uid() and p.can_fulfill
  );
$$;
revoke all on function public.can_request() from public, anon;
revoke all on function public.can_fulfill() from public, anon;
grant execute on function public.can_request() to authenticated;
grant execute on function public.can_fulfill() to authenticated;


-- ---------------------------------------------------------------------
-- 2) الجداول
-- ---------------------------------------------------------------------
-- عدّاد ترقيم REQ-YYYY-NNNN (ذرّي، لا يُكرَّر الرقم أبداً)
create table if not exists public.outbound_counters (
  year     int primary key,
  last_seq int not null default 0
);

create table if not exists public.outbound_requests (
  id             uuid primary key default gen_random_uuid(),
  req_no         text not null unique,
  requester_id   uuid not null references auth.users(id),
  requester_name text not null,
  status         text not null default 'pending'
                 check (status in ('pending','in_progress','partial','completed','cancelled')),
  note           text,
  client_token   uuid unique,            -- يمنع تكرار الطلب عند ضغطتين/إعادة محاولة بعد انقطاع شبكة
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists outbound_requests_requester_idx on public.outbound_requests (requester_id, created_at desc);
create index if not exists outbound_requests_status_idx    on public.outbound_requests (status, created_at desc);

create table if not exists public.outbound_request_items (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null references public.outbound_requests(id) on delete restrict,
  line_no       int  not null,
  material_src  text not null check (material_src in ('goods','stock')),  -- goods = مخزون المستودع، stock = مواد 4G
  material_key  text not null,           -- مفتاح المادة الأصلية في الكتالوج (لا نسخ مكررة)
  material_name text not null,
  site          text not null,
  recipient     text,
  qty_requested numeric not null check (qty_requested > 0),
  qty_done      numeric not null default 0 check (qty_done >= 0),
  note          text,
  unique (request_id, line_no),
  check (qty_done <= qty_requested)
);
create index if not exists outbound_items_request_idx on public.outbound_request_items (request_id);

create table if not exists public.outbound_executions (
  id               uuid primary key default gen_random_uuid(),
  request_id       uuid not null references public.outbound_requests(id) on delete restrict,
  item_id          uuid not null references public.outbound_request_items(id) on delete restrict,
  qty              numeric not null check (qty > 0),
  executed_by      uuid not null,
  executed_by_name text,
  executed_at      timestamptz not null default now(),
  ledger_ref       text,                 -- معرّف/معرّفات حركة الإخراج في سجل المخزون (goodsLedger/ledger) المرتبطة بهذا الـ REQ
  note             text,
  voided_at        timestamptz,          -- التراجع لا يحذف شيئاً: يُعلَّم السجل فقط
  voided_by        uuid
);
alter table public.outbound_executions add column if not exists voided_at timestamptz;
alter table public.outbound_executions add column if not exists voided_by uuid;
create index if not exists outbound_exec_request_idx on public.outbound_executions (request_id, executed_at);

create table if not exists public.outbound_notifications (
  id             uuid primary key default gen_random_uuid(),
  request_id     uuid not null unique references public.outbound_requests(id) on delete restrict,  -- unique = تنبيه واحد فقط لكل طلب
  req_no         text not null,
  requester_name text not null,
  title          text not null,
  body           text not null,
  created_at     timestamptz not null default now(),
  resolved       boolean not null default false,
  resolved_at    timestamptz,
  resolved_by    uuid
);
create index if not exists outbound_notif_open_idx on public.outbound_notifications (resolved, created_at desc);

create table if not exists public.outbound_favorites (
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  material_src  text not null check (material_src in ('goods','stock')),
  material_key  text not null,
  material_name text not null,
  pinned_at     timestamptz not null default now(),
  primary key (user_id, material_src, material_key)   -- مرجع للمادة الأصلية فقط، لا ينشئ مادة جديدة
);


-- ---------------------------------------------------------------------
-- 3) RLS — القراءة فقط مباشرة؛ كل الكتابة عبر دوال RPC تتحقق من الصلاحية داخل قاعدة البيانات
-- ---------------------------------------------------------------------
alter table public.outbound_counters      enable row level security;   -- لا سياسات = لا وصول مباشر
alter table public.outbound_requests      enable row level security;
alter table public.outbound_request_items enable row level security;
alter table public.outbound_executions    enable row level security;
alter table public.outbound_notifications enable row level security;
alter table public.outbound_favorites     enable row level security;

drop policy if exists outbound_requests_select on public.outbound_requests;
create policy outbound_requests_select on public.outbound_requests for select to authenticated
  using (requester_id = auth.uid() or public.can_fulfill());

drop policy if exists outbound_items_select on public.outbound_request_items;
create policy outbound_items_select on public.outbound_request_items for select to authenticated
  using (exists (select 1 from public.outbound_requests r where r.id = request_id));   -- يرث رؤية الطلب

drop policy if exists outbound_exec_select on public.outbound_executions;
create policy outbound_exec_select on public.outbound_executions for select to authenticated
  using (exists (select 1 from public.outbound_requests r where r.id = request_id));

drop policy if exists outbound_notif_select on public.outbound_notifications;
create policy outbound_notif_select on public.outbound_notifications for select to authenticated
  using (public.is_admin());

drop policy if exists outbound_fav_select on public.outbound_favorites;
create policy outbound_fav_select on public.outbound_favorites for select to authenticated
  using (user_id = auth.uid());
drop policy if exists outbound_fav_insert on public.outbound_favorites;
create policy outbound_fav_insert on public.outbound_favorites for insert to authenticated
  with check (user_id = auth.uid() and public.can_request());
drop policy if exists outbound_fav_delete on public.outbound_favorites;
create policy outbound_fav_delete on public.outbound_favorites for delete to authenticated
  using (user_id = auth.uid());

-- حزام أمان ثانٍ: سحب كل صلاحيات الجداول ثم منح القراءة فقط (RLS تبقى الطبقة الأولى).
-- مهم في Supabase: الصلاحيات الافتراضية تمنح anon و authenticated كل شيء على أي جدول جديد.
revoke all on public.outbound_counters, public.outbound_requests, public.outbound_request_items,
              public.outbound_executions, public.outbound_notifications, public.outbound_favorites,
              public.wms_user_perms from anon, authenticated;
grant select on public.outbound_requests, public.outbound_request_items, public.outbound_executions,
                public.outbound_notifications, public.wms_user_perms to authenticated;
grant select, insert, delete on public.outbound_favorites to authenticated;


-- ---------------------------------------------------------------------
-- 4) إنشاء طلب — رقم REQ تلقائي + بنود + تنبيه واحد للإدارة (ذرّي في معاملة واحدة)
-- ---------------------------------------------------------------------
create or replace function public.outbound_create_request(
  p_items jsonb, p_note text default null, p_client_token uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_name text; v_year int; v_seq int; v_req_no text; v_id uuid;
  v_item jsonb; v_line int := 0; v_ex public.outbound_requests;
  v_qty numeric; v_site text; v_mat text;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if not public.can_request() then raise exception 'forbidden: outbound request permission required'; end if;

  if p_client_token is not null then
    select * into v_ex from public.outbound_requests where client_token = p_client_token and requester_id = v_uid;
    if found then
      return jsonb_build_object('id', v_ex.id, 'req_no', v_ex.req_no, 'duplicate', true);
    end if;
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'items required';
  end if;
  if jsonb_array_length(p_items) > 500 then raise exception 'too many items (max 500)'; end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_mat  := nullif(trim(coalesce(v_item->>'material_key','')), '');
    v_site := nullif(trim(coalesce(v_item->>'site','')), '');
    if coalesce(v_item->>'material_src','') not in ('goods','stock') then raise exception 'invalid material_src'; end if;
    if v_mat is null or nullif(trim(coalesce(v_item->>'material_name','')), '') is null then raise exception 'material required'; end if;
    if v_site is null then raise exception 'site required'; end if;
    begin v_qty := (v_item->>'qty')::numeric; exception when others then raise exception 'invalid qty'; end;
    if v_qty is null or v_qty <= 0 or v_qty > 1000000 then raise exception 'invalid qty'; end if;
  end loop;

  v_name := coalesce(
    (select nullif(trim(p.display_name), '') from public.wms_user_perms p where p.user_id = v_uid),
    nullif(split_part(coalesce(auth.jwt()->>'email',''), '@', 1), ''),
    'مستخدم');

  v_year := extract(year from (now() at time zone 'Asia/Hebron'))::int;
  insert into public.outbound_counters (year, last_seq) values (v_year, 1)
    on conflict (year) do update set last_seq = public.outbound_counters.last_seq + 1
    returning last_seq into v_seq;
  v_req_no := 'REQ-' || v_year || '-' || lpad(v_seq::text, 4, '0');

  insert into public.outbound_requests (req_no, requester_id, requester_name, note, client_token)
    values (v_req_no, v_uid, v_name, nullif(left(trim(coalesce(p_note,'')), 500), ''), p_client_token)
    returning id into v_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_line := v_line + 1;
    insert into public.outbound_request_items
      (request_id, line_no, material_src, material_key, material_name, site, recipient, qty_requested, note)
    values (v_id, v_line, v_item->>'material_src', trim(v_item->>'material_key'), trim(v_item->>'material_name'),
            left(trim(v_item->>'site'), 200), nullif(left(trim(coalesce(v_item->>'recipient','')), 200), ''),
            (v_item->>'qty')::numeric, nullif(left(trim(coalesce(v_item->>'note','')), 500), ''));
  end loop;

  -- تنبيه واحد فقط لكل طلب (unique على request_id) حتى لو أُعيد استدعاء الدالة
  insert into public.outbound_notifications (request_id, req_no, requester_name, title, body)
    values (v_id, v_req_no, v_name, '🔔 طلب إخراج جديد', v_name || ' أرسل طلب إخراج جديد')
    on conflict (request_id) do nothing;

  return jsonb_build_object('id', v_id, 'req_no', v_req_no, 'duplicate', false);
end;
$$;

-- ---------------------------------------------------------------------
-- 5) تسجيل تنفيذ كمية لسطر (يُستدعى بعد تسجيل حركة الإخراج في مخزون النظام الحالي)
--    يقفل السطر (FOR UPDATE) لمنع تجاوز الكمية المطلوبة عند تنفيذين متزامنين، ثم يعيد حساب حالة الطلب.
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

-- تراجع عن تسجيل تنفيذ (يُستخدم فقط كتعويض تلقائي إذا فشل تسجيل حركة المخزون بعد حجز الكمية)
create or replace function public.outbound_undo_execution(p_execution_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_e public.outbound_executions; v_all boolean; v_any boolean; v_status text; v_cur text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.can_fulfill() then raise exception 'forbidden: fulfill permission required'; end if;
  select * into v_e from public.outbound_executions where id = p_execution_id for update;
  if not found then raise exception 'execution not found'; end if;
  if v_e.voided_at is not null then raise exception 'execution already voided'; end if;
  if v_e.executed_by <> auth.uid() and not public.is_admin() then raise exception 'forbidden'; end if;
  if v_e.executed_at < now() - interval '10 minutes' then raise exception 'too old to undo'; end if;
  update public.outbound_request_items set qty_done = greatest(0, qty_done - v_e.qty) where id = v_e.item_id;
  update public.outbound_executions set voided_at = now(), voided_by = auth.uid() where id = p_execution_id;
  select status into v_cur from public.outbound_requests where id = v_e.request_id for update;
  select bool_and(qty_done >= qty_requested), bool_or(qty_done > 0) into v_all, v_any
    from public.outbound_request_items where request_id = v_e.request_id;
  v_status := case when v_all then 'completed' when v_any then 'partial'
                   when v_cur = 'completed' or v_cur = 'partial' then 'pending' else v_cur end;
  update public.outbound_requests set status = v_status, updated_at = now() where id = v_e.request_id;
  return jsonb_build_object('request_status', v_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 6) تغيير حالة الطلب يدوياً من المستودع/الإدارة: قيد التنفيذ، أو ملغي
--    (مكتمل/منفذ جزئياً تُحسب تلقائياً من الكميات المنفَّذة فقط)
-- ---------------------------------------------------------------------
create or replace function public.outbound_set_status(p_request_id uuid, p_status text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_req public.outbound_requests;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not public.can_fulfill() then raise exception 'forbidden: fulfill permission required'; end if;
  if p_status not in ('in_progress','cancelled') then raise exception 'unsupported status'; end if;
  select * into v_req from public.outbound_requests where id = p_request_id for update;
  if not found then raise exception 'request not found'; end if;
  if v_req.status in ('completed','cancelled') then raise exception 'request is already %', v_req.status; end if;
  if p_status = 'in_progress' and v_req.status <> 'pending' then raise exception 'only pending requests can move to in_progress'; end if;
  update public.outbound_requests set status = p_status, updated_at = now() where id = p_request_id;
  return jsonb_build_object('request_status', p_status);
end;
$$;

-- ---------------------------------------------------------------------
-- 7) إزالة التنبيه (مدير فقط) — فتح الطلب لا يزيل التنبيه؛ هذه الدالة فقط
-- ---------------------------------------------------------------------
create or replace function public.outbound_resolve_notification(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden: admin role required'; end if;
  update public.outbound_notifications
     set resolved = true, resolved_at = now(), resolved_by = auth.uid()
   where id = p_id and not resolved;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 8) الأكثر استخداماً: من واقع طلبات المستخدم نفسه (SECURITY INVOKER = RLS تبقى سارية)
-- ---------------------------------------------------------------------
create or replace function public.outbound_top_materials(p_limit int default 8)
returns table (material_src text, material_key text, material_name text, uses bigint)
language sql stable security invoker set search_path = public as $$
  select i.material_src, i.material_key,
         (array_agg(i.material_name order by r.created_at desc))[1] as material_name,
         count(*) as uses
    from public.outbound_request_items i
    join public.outbound_requests r on r.id = i.request_id
   where r.requester_id = auth.uid() and r.status <> 'cancelled'
   group by i.material_src, i.material_key
   order by count(*) desc, max(r.created_at) desc
   limit greatest(1, least(coalesce(p_limit, 8), 50));
$$;

revoke all on function public.outbound_create_request(jsonb, text, uuid)        from public;
revoke all on function public.outbound_record_execution(uuid, numeric, text, text) from public;
revoke all on function public.outbound_undo_execution(uuid)                     from public;
revoke all on function public.outbound_set_status(uuid, text)                   from public;
revoke all on function public.outbound_resolve_notification(uuid)               from public;
revoke all on function public.outbound_top_materials(int)                       from public;
revoke execute on function public.outbound_create_request(jsonb, text, uuid), public.outbound_record_execution(uuid, numeric, text, text),
  public.outbound_undo_execution(uuid), public.outbound_set_status(uuid, text),
  public.outbound_resolve_notification(uuid), public.outbound_top_materials(int) from anon;
grant execute on function public.outbound_create_request(jsonb, text, uuid)        to authenticated;
grant execute on function public.outbound_record_execution(uuid, numeric, text, text) to authenticated;
grant execute on function public.outbound_undo_execution(uuid)                     to authenticated;
grant execute on function public.outbound_set_status(uuid, text)                   to authenticated;
grant execute on function public.outbound_resolve_notification(uuid)               to authenticated;
grant execute on function public.outbound_top_materials(int)                       to authenticated;


-- ---------------------------------------------------------------------
-- 9) تنفيذ الإخراج يحدّث مخزون النظام الحالي (wms_state) — صلاحية كتابة إضافية ومحدودة
--    مخزون النظام الحالي محفوظ كنصوص JSON داخل wms_state، وكتابته مقتصرة اليوم على admin.
--    ليتمكن موظف المستودع (can_fulfill) من تنفيذ الإخراج بنفس آلية النظام الحالية، تُضاف سياستا
--    insert/update إضافيتان (permissive، تُجمَعان بـ OR مع سياسات admin الحالية دون تعديلها) تسمحان
--    له بكتابة 4 مفاتيح مخزون فقط: مخزون المستودع (كتالوج + سجل) ومواد 4G (رصيد + سجل).
--    لا حذف (delete)، ولا أي مفتاح آخر (SID، تاجات، نسخ احتياطي...).
--    المقايضة المعلنة: مخزون النظام blob واحد لكل مفتاح، فمن يملك can_fulfill يستطيع نظرياً
--    استبدال blob المخزون عبر API مباشرة — لذا تُمنح can_fulfill لموظفي المستودع الموثوقين فقط.
-- ---------------------------------------------------------------------
drop policy if exists wms_state_insert_fulfiller on public.wms_state;
create policy wms_state_insert_fulfiller on public.wms_state for insert to authenticated
  with check (public.can_fulfill() and key in
    ('wms_goods_catalog_v1','wms_goods_ledger_v1','wms_stock_v1','wms_ledger_v1'));
drop policy if exists wms_state_update_fulfiller on public.wms_state;
create policy wms_state_update_fulfiller on public.wms_state for update to authenticated
  using      (public.can_fulfill() and key in ('wms_goods_catalog_v1','wms_goods_ledger_v1','wms_stock_v1','wms_ledger_v1'))
  with check (public.can_fulfill() and key in ('wms_goods_catalog_v1','wms_goods_ledger_v1','wms_stock_v1','wms_ledger_v1'));


-- ---------------------------------------------------------------------
-- 9b) إغلاق ثغرات الكتابة الموجودة أصلاً في المشروع الحي (اكتُشفت عند الفحص قبل التنفيذ):
--     • wms_state كان فيها سياستا insert/update لدور public (أي شخص بمفتاح النشر يستطيع الكتابة
--       على كل المفاتيح: المخزون، SID، التاجات...). تُستبدل بسياسات المدير فقط (+ سياسة موظف المستودع
--       المحدودة أعلاه). القراءة (anon read) تبقى كما هي دون تغيير.
--     • profiles كانت تسمح لأي مستخدم بتعديل صفّه بما فيه role (ترقية نفسه إلى admin). الواجهة تقرأ
--       profiles فقط ولا تكتب فيها أبداً، فتُسحب صلاحيات الكتابة عليها (الترقية تبقى يدوية من Supabase).
--     • سحب TRUNCATE/TRIGGER/REFERENCES من anon/authenticated على الجداول القائمة.
--     لا يمس أي بيانات.
-- ---------------------------------------------------------------------
-- ALTER POLICY (وليس DROP) لتبقى السياسات القائمة بأسمائها وتتحول إلى "مدير فقط"، ويعاد تنفيذ الملف بأمان.
do $do$
begin
  if exists (select 1 from pg_policies where schemaname='public' and tablename='wms_state' and policyname='anon insert') then
    alter policy "anon insert" on public.wms_state to authenticated with check (public.is_admin());
  elsif not exists (select 1 from pg_policies where schemaname='public' and tablename='wms_state' and policyname='wms_state_insert_admin') then
    create policy wms_state_insert_admin on public.wms_state for insert to authenticated with check (public.is_admin());
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='wms_state' and policyname='anon update') then
    alter policy "anon update" on public.wms_state to authenticated using (public.is_admin()) with check (public.is_admin());
  elsif not exists (select 1 from pg_policies where schemaname='public' and tablename='wms_state' and policyname='wms_state_update_admin') then
    create policy wms_state_update_admin on public.wms_state for update to authenticated using (public.is_admin()) with check (public.is_admin());
  end if;
end $do$;
revoke delete, truncate, references, trigger on public.wms_state from anon, authenticated;
revoke insert, update on public.wms_state from anon;
revoke insert, update, delete, truncate, references, trigger on public.profiles from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger on public.wms_backups from anon, authenticated;


-- ---------------------------------------------------------------------
-- 10) منح الصلاحيات (يدوياً، بعد المراجعة) — عدّل البريد ثم نفّذ ما تحتاجه
-- ---------------------------------------------------------------------
-- حساب "أبو أيوب" (مستخدم عادي viewer + صلاحية طلب الإخراج فقط):
-- insert into public.wms_user_perms (user_id, display_name, can_request)
--   select id, 'أبو أيوب', true from auth.users where email = 'ABU_AYOUB_EMAIL@example.com'
--   on conflict (user_id) do update set display_name = excluded.display_name, can_request = true;
--
-- موظف مستودع (ينفّذ الطلبات):
-- insert into public.wms_user_perms (user_id, display_name, can_fulfill)
--   select id, 'اسم الموظف', true from auth.users where email = 'WAREHOUSE_EMAIL@example.com'
--   on conflict (user_id) do update set display_name = excluded.display_name, can_fulfill = true;
