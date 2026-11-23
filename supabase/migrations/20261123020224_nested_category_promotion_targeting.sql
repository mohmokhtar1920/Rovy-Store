-- Keep the SHEIN category tree and ensure promotions on a parent category
-- include products assigned to any descendant category.
begin;

do $$
declare
  v_root_id bigint;
  v_women_id bigint;
begin
  select id into v_root_id
  from public.product_categories
  where lower(btrim(name))=lower('SHEIN') and parent_id is null
  limit 1;

  if v_root_id is null then
    insert into public.product_categories(name,parent_id,is_active,sort_order)
    values('SHEIN',null,true,10)
    returning id into v_root_id;
  end if;

  select id into v_women_id
  from public.product_categories
  where lower(btrim(name))=lower('حريمي')
  limit 1;

  if v_women_id is not null then
    update public.product_categories
    set parent_id=v_root_id,is_active=true,sort_order=10
    where id=v_women_id and parent_id is null;

    update public.products
    set category='SHEIN / حريمي'
    where category='حريمي';
  end if;

  if not exists (
    select 1 from public.product_categories
    where lower(btrim(name))=lower('أطفال')
  ) then
    insert into public.product_categories(name,parent_id,is_active,sort_order)
    values('أطفال',v_root_id,true,20);
  end if;
end $$;

do $$
declare
  v_oid oid;
  v_def text;
  v_old text := '(v_promo.target_category IS NOT NULL AND pr.category=v_promo.target_category)';
  v_new text := '(v_promo.target_category IS NOT NULL AND (pr.category=v_promo.target_category OR left(pr.category,length(v_promo.target_category)+3)=v_promo.target_category||'' / ''))';
begin
  foreach v_oid in array array[
    to_regprocedure('public.preview_order_discounts(jsonb,text)')::oid,
    to_regprocedure('public.create_order_secure(text,text,text,jsonb,text)')::oid
  ] loop
    if v_oid is null then
      raise exception 'Required discount function not found';
    end if;

    select pg_get_functiondef(v_oid) into v_def;

    if position(v_old in v_def)>0 then
      v_def := replace(v_def,v_old,v_new);
      execute v_def;
    elsif position('left(pr.category,length(v_promo.target_category)+3)' in v_def)=0 then
      raise exception 'Expected category targeting clause not found in %',v_oid::regprocedure;
    end if;
  end loop;
end $$;

commit;
