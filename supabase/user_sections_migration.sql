-- =====================================================================
-- إدارة صلاحيات الأقسام لكل مستخدم (User Sections Permissions)
--
-- مبدأ التصميم: إضافة فقط (additive) — لا يحذف ولا يعدّل أي بيانات موجودة:
--   • يضيف عمود profiles.sections (JSONB) لتخزين خريطة صلاحيات كل مستخدم.
--   • sections = NULL  => الوضع الافتراضي القديم (عرض: مخزون 4G، المستودع، سجل التاجات).
--   • sections = '{}'  => كل الأقسام مخفية.
--   • أي قسم غير مذكور داخل الخريطة = مخفي.
--   • القيم المسموحة لكل قسم: 'none' | 'read' | 'edit'.
--   • role='admin' يتجاوز الخريطة ويملك كل الأقسام دائماً.
--
-- الكتابة على wms_state تبقى محصورة بالمدير عبر RLS الحالية. المستخدم غير المدير
-- الذي يملك صلاحية 'edit' على قسم يكتب فقط عبر الدالة wms_write_state() المحمية،
-- وهي تتحقق من مفتاح wms_state وقسمه قبل الحفظ. لا تُفتح أي سياسة كتابة جديدة.
--
-- لا يُنفَّذ تلقائياً من أي جلسة: انسخه إلى Supabase SQL Editor بعد المراجعة والموافقة.
-- آمن لإعادة التنفيذ (idempotent).
--
-- ملاحظة أمنية: profiles مقروء حالياً للزوار (مشكلة قائمة من تدقيق سابق). هذا الملف
-- لا يغيّر سياسات القراءة حتى لا يكسر تسجيل الدخول، لكنه يمنع أي كتابة مباشرة على
-- profiles من anon/authenticated. إدارة الصلاحيات تمر حصراً عبر الدوال الإدارية.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) عمود الصلاحيات
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists sections jsonb;

comment on column public.profiles.sections is
  'خريطة صلاحيات الأقسام: null = الوضع الافتراضي القديم، {} = كل الأقسام مخفية، وإلا {section_id: none|read|edit}';

-- منع أي كتابة مباشرة من المتصفح على profiles (الكتابة عبر الدوال الإدارية فقط)
revoke insert, update, delete on public.profiles from anon, authenticated;


-- ---------------------------------------------------------------------
-- 2) is_admin() — موجودة عادةً من migration طلبات الإخراج، نعيد إنشاءها بأمان
-- ---------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  );
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;


-- ---------------------------------------------------------------------
-- 3) قائمة المستخدمين للمدير (تشمل البريد والدور والصلاحيات)
-- ---------------------------------------------------------------------
create or replace function public.wms_admin_list_users()
returns table (
  id uuid,
  email text,
  role text,
  sections jsonb,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'forbidden: admin only';
  end if;
  return query
    select p.id, p.email, p.role, p.sections, p.updated_at
    from public.profiles p
    order by coalesce(p.email, '') asc;
end;
$$;
revoke all on function public.wms_admin_list_users() from public, anon;
grant execute on function public.wms_admin_list_users() to authenticated;


-- ---------------------------------------------------------------------
-- 4) حفظ صلاحيات مستخدم (مدير فقط)
--    p_sections = NULL => إرجاع المستخدم للوضع الافتراضي القديم.
--    p_sections = '{}' => إخفاء كل الأقسام.
-- ---------------------------------------------------------------------
create or replace function public.wms_admin_set_user_sections(
  p_user uuid,
  p_sections jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_val text;
  v_clean jsonb := '{}'::jsonb;
  v_exists boolean;
begin
  if not public.is_admin() then
    raise exception 'forbidden: admin only';
  end if;

  if p_sections is not null then
    if jsonb_typeof(p_sections) <> 'object' then
      raise exception 'invalid sections payload: object required';
    end if;
    for v_key, v_val in
      select e.key, e.value #>> '{}'
      from jsonb_each(p_sections) e
    loop
      if v_key in (
        'setup','sid','stock','quick','goods','outreq',
        'tagcapture','taglog','transport','dyn'
      ) and v_val in ('none','read','edit') then
        -- «مخزون 4G» و«سجل التاجات» عرض فقط بطبيعتهما؛ لا نسمح بتخزين edit لهما
        -- حتى لو نادت الواجهة/الـ API قيمة غير متوقعة.
        if v_key in ('stock','taglog') and v_val = 'edit' then
          v_val := 'read';
        end if;
        v_clean := v_clean || jsonb_build_object(v_key, v_val);
      end if;
    end loop;
  end if;

  select exists(select 1 from public.profiles p where p.id = p_user) into v_exists;
  if not v_exists then
    raise exception 'user not found';
  end if;

  update public.profiles
     set sections = case when p_sections is null then null else v_clean end,
         updated_at = now()
   where id = p_user;
end;
$$;
revoke all on function public.wms_admin_set_user_sections(uuid, jsonb) from public, anon;
grant execute on function public.wms_admin_set_user_sections(uuid, jsonb) to authenticated;


-- ---------------------------------------------------------------------
-- 4b) ربط can_request / can_fulfill بصلاحية قسم «طلبات الإخراج»
--     القاعدة:
--       • sections = NULL (حساب قديم) => نفس wms_user_perms القديمة بلا تغيير.
--       • sections صريحة => قسم outreq = 'edit' فقط يمنح الإنشاء/التنفيذ.
--       • admin => دائماً.
--     هذا يمنع مستخدم «قراءة فقط» من استدعاء دوال RPC للإنشاء/التنفيذ مباشرة.
-- ---------------------------------------------------------------------
create or replace function public.can_request()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin() or exists (
    select 1
      from public.profiles p
     where p.id = auth.uid()
       and (
         (p.sections is not null and p.sections ->> 'outreq' = 'edit')
         or (
           p.sections is null
           and exists (
             select 1 from public.wms_user_perms up
              where up.user_id = auth.uid() and up.can_request
           )
         )
       )
  );
$$;
revoke all on function public.can_request() from public, anon;
grant execute on function public.can_request() to authenticated;

create or replace function public.can_fulfill()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin() or exists (
    select 1
      from public.profiles p
     where p.id = auth.uid()
       and (
         (p.sections is not null and p.sections ->> 'outreq' = 'edit')
         or (
           p.sections is null
           and exists (
             select 1 from public.wms_user_perms up
              where up.user_id = auth.uid() and up.can_fulfill
           )
         )
       )
  );
$$;
revoke all on function public.can_fulfill() from public, anon;
grant execute on function public.can_fulfill() to authenticated;


-- ---------------------------------------------------------------------
-- 4c) قراءة طلبات الإخراج: من يملك outreq = read أو edit يرى كل الطلبات
--     السياسة القديمة كانت تسمح للمقدّم أو can_fulfill فقط، لذا مستخدم
--     «قراءة فقط» لم يكن يرى إلا طلباته. عناصر الطلب وتنفيذاته ترث الرؤية
--     من سياساتها الحالية القائمة على رؤية الطلب نفسه.
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.outbound_requests') is not null then
    execute 'drop policy if exists outbound_requests_select on public.outbound_requests';
    execute $sql$
      create policy outbound_requests_select on public.outbound_requests
        for select to authenticated
        using (
          requester_id = auth.uid()
          or public.can_fulfill()
          or exists (
            select 1
              from public.profiles p
             where p.id = auth.uid()
               and p.sections is not null
               and p.sections ->> 'outreq' in ('read','edit')
          )
        )
    $sql$;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 5) ربط مفاتيح wms_state بالأقسام + فحص صلاحية التعديل
--    يُستخدم داخل wms_write_state() فقط. المدير يمر دائماً.
-- ---------------------------------------------------------------------
create or replace function public.can_edit_state_key(p_key text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sections jsonb;
begin
  if public.is_admin() then
    return true;
  end if;

  select p.sections into v_sections
    from public.profiles p
   where p.id = auth.uid();

  if v_sections is null then
    -- توافق خلفي: مستخدم can_fulfill قديم (قبل الصلاحيات) يبقى قادراً على كتابة
    -- مفاتيح المخزون الأربعة التي يحتاجها تنفيذ طلبات الإخراج، كما كان الوضع سابقاً.
    return public.can_fulfill() and p_key in (
      'wms_goods_catalog_v1','wms_goods_ledger_v1','wms_stock_v1','wms_ledger_v1'
    );
  end if;

  return exists (
    select 1
      from (values
        ('wms_stock_v1',            'setup'),
        ('wms_stock_v1',            'sid'),
        ('wms_stock_v1',            'quick'),
        ('wms_stock_v1',            'tagcapture'),
        ('wms_stock_v1',            'outreq'),
        ('wms_dismantled_v1',       'setup'),
        ('wms_dismantled_v1',       'quick'),
        ('wms_ledger_v1',           'setup'),
        ('wms_ledger_v1',           'sid'),
        ('wms_ledger_v1',           'quick'),
        ('wms_ledger_v1',           'outreq'),
        ('wms_processed_sids_v1',   'sid'),
        ('wms_processed_files_v1',  'setup'),
        ('wms_meta_v1',             'setup'),
        ('wms_issues_v1',           'setup'),
        ('wms_issues_v1',           'sid'),
        ('wms_issues_v1',           'quick'),
        ('wms_issues_v1',           'goods'),
        ('wms_goods_catalog_v1',    'goods'),
        ('wms_goods_catalog_v1',    'quick'),
        ('wms_goods_catalog_v1',    'outreq'),
        ('wms_goods_ledger_v1',     'goods'),
        ('wms_goods_ledger_v1',     'quick'),
        ('wms_goods_ledger_v1',     'outreq'),
        ('wms_tag_log_v1',          'tagcapture'),
        ('wms_tag_log_template_v1', 'tagcapture'),
        ('wms_tag_sites_v1',        'tagcapture'),
        ('wms_tag_shortcuts_v1',    'tagcapture'),
        ('wms_sid_review_v1',       'sid'),
        ('wms_site_schedule_v1',    'sid'),
        ('wms_sid_highlights_v1',   'sid')
      ) as m(k, section)
     where m.k = p_key
       and v_sections ->> m.section = 'edit'
  );
end;
$$;
revoke all on function public.can_edit_state_key(text) from public, anon;
grant execute on function public.can_edit_state_key(text) to authenticated;


-- ---------------------------------------------------------------------
-- 6) الكتابة الآمنة على wms_state لغير المدير (عبر RPC فقط)
--    نفس شكل الصف المستخدم في التطبيق: key, value(text), updated_at.
-- ---------------------------------------------------------------------
create or replace function public.wms_write_state(p_key text, p_value text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  if not public.can_edit_state_key(p_key) then
    raise exception 'forbidden: no edit permission for this section';
  end if;

  insert into public.wms_state(key, value, updated_at)
  values (p_key, p_value, now())
  on conflict (key) do update
    set value = excluded.value,
        updated_at = excluded.updated_at;
end;
$$;
revoke all on function public.wms_write_state(text, text) from public, anon;
grant execute on function public.wms_write_state(text, text) to authenticated;


-- ---------------------------------------------------------------------
-- 7) إغلاق الكتابة المباشرة القديمة على wms_state أمام can_fulfill
--    migration طلبات الإخراج كانت تسمح لـ can_fulfill بكتابة 4 مفاتيح مباشرة.
--    نُبقي الأسماء نفسها لكن نضيف شرط صلاحية القسم، حتى لا يتجاوز مستخدم
--    can_fulfill صلاحيات الأقسام عبر طلب REST مباشر.
--    (نفّذ هذا الملف بعد outbound_requests_migration.sql إن أعدت تنفيذ الأخير.)
-- ---------------------------------------------------------------------
drop policy if exists wms_state_insert_fulfiller on public.wms_state;
create policy wms_state_insert_fulfiller on public.wms_state for insert to authenticated
  with check (
    key in ('wms_goods_catalog_v1','wms_goods_ledger_v1','wms_stock_v1','wms_ledger_v1')
    and public.can_edit_state_key(key)
  );

drop policy if exists wms_state_update_fulfiller on public.wms_state;
create policy wms_state_update_fulfiller on public.wms_state for update to authenticated
  using (
    key in ('wms_goods_catalog_v1','wms_goods_ledger_v1','wms_stock_v1','wms_ledger_v1')
    and public.can_edit_state_key(key)
  )
  with check (
    key in ('wms_goods_catalog_v1','wms_goods_ledger_v1','wms_stock_v1','wms_ledger_v1')
    and public.can_edit_state_key(key)
  );


-- ---------------------------------------------------------------------
-- 8) تحديث كاش PostgREST ليرى العمود والدوال الجديدة فوراً
-- ---------------------------------------------------------------------
notify pgrst, 'reload schema';


-- =====================================================================
-- بعد التنفيذ:
--   1) أعد تحميل التطبيق.
--   2) ادخل بحساب مدير، وافتح تبويب «👥 المستخدمون والصلاحيات».
--   3) اضبط لكل مستخدم: مخفي / قراءة / تعديل لكل قسم.
--
-- للتحقق السريع من التطبيق (اختياري):
--   select id, email, role, sections from public.profiles order by email;
-- =====================================================================
