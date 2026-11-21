create or replace function public.customer_preview_exchange_replacement_items(
  p_request_id bigint,
  p_items jsonb
) returns json
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_req private.return_requests%rowtype;
  v_original public.orders%rowtype;
  v_units integer;
  v_requested integer;
  v_original_subtotal numeric(12,2);
  v_return_gross numeric(12,2);
  v_credit numeric(12,2);
  v_replacement_value numeric(12,2) := 0;
  v_shipping numeric(12,2);
  v_item jsonb;
  v_product_id bigint;
  v_variant_id bigint;
  v_qty integer;
  v_product public.products%rowtype;
  v_variant public.product_variants%rowtype;
  v_has_variants boolean;
begin
  if v_uid is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not exists(select 1 from auth.users u where u.id=v_uid and u.email_confirmed_at is not null) then
    raise exception 'يجب تأكيد البريد الإلكتروني أولاً';
  end if;
  select * into v_req from private.return_requests
  where id=p_request_id and customer_user_id=v_uid for share;
  if not found or v_req.request_type<>'exchange' or v_req.status<>'exchange_pending'
     or v_req.replacement_order_id is not null then
    raise exception 'طلب الاستبدال غير متاح للمعاينة';
  end if;
  select * into v_original from public.orders
  where id=v_req.order_id and customer_user_id=v_uid;
  if not found or v_original.status<>'delivered' then raise exception 'الطلب الأصلي غير متاح'; end if;
  select coalesce(sum(accepted_quantity),0)::integer into v_units
  from private.return_request_items where return_request_id=p_request_id and accepted_quantity>0;
  if v_units<1 then raise exception 'لا توجد قطع معتمدة للاستبدال'; end if;
  if p_items is null or pg_catalog.jsonb_typeof(p_items)<>'array'
     or pg_catalog.jsonb_array_length(p_items)<1 or pg_catalog.jsonb_array_length(p_items)>30 then
    raise exception 'اختيارات المنتجات غير صحيحة';
  end if;
  select coalesce(sum((x.value->>'quantity')::integer),0)::integer into v_requested
  from pg_catalog.jsonb_array_elements(p_items) x(value);
  if v_requested<>v_units then raise exception 'يجب توزيع نفس عدد القطع المعتمدة على المنتجات البديلة'; end if;
  if exists (
    select 1 from (
      select (x.value->>'product_id')::bigint product_id,
             nullif(x.value->>'variant_id','')::bigint variant_id
      from pg_catalog.jsonb_array_elements(p_items) x(value)
    ) d group by product_id,variant_id having count(*)>1
  ) then raise exception 'احذف الاختيارات المكررة واجمع كمياتها في سطر واحد'; end if;
  for v_item in select value from pg_catalog.jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'product_id')::bigint;
    v_qty := (v_item->>'quantity')::integer;
    v_variant_id := nullif(v_item->>'variant_id','')::bigint;
    if v_product_id is null or v_product_id<1 or v_qty is null or v_qty<1 then
      raise exception 'بيانات أحد المنتجات غير صحيحة';
    end if;
    select * into v_product from public.products where id=v_product_id and is_active is true;
    if not found then raise exception 'أحد المنتجات لم يعد متاحاً'; end if;
    select exists(select 1 from public.product_variants where product_id=v_product_id) into v_has_variants;
    if v_variant_id is not null then
      select * into v_variant from public.product_variants
      where id=v_variant_id and product_id=v_product_id and stock>=v_qty;
      if not found then raise exception 'المقاس أو اللون غير متاح بالكمية المطلوبة'; end if;
      if v_variant.size is distinct from nullif(v_item->>'size','')
         or v_variant.color is distinct from nullif(v_item->>'color','') then
        raise exception 'بيانات المقاس أو اللون غير متطابقة';
      end if;
    else
      if v_has_variants then raise exception 'يجب اختيار المقاس واللون لأحد المنتجات'; end if;
      if coalesce(v_product.stock,0)<v_qty then raise exception 'الكمية المطلوبة من أحد المنتجات غير متاحة'; end if;
    end if;
    v_replacement_value := v_replacement_value + (v_product.price*v_qty);
  end loop;
  select coalesce(sum(price*quantity),0) into v_original_subtotal
  from public.order_items where order_id=v_req.order_id;
  select coalesce(sum(accepted_quantity*unit_price),0) into v_return_gross
  from private.return_request_items where return_request_id=p_request_id and accepted_quantity>0;
  if v_original_subtotal<=0 or v_return_gross<=0 then raise exception 'تعذر حساب رصيد الاستبدال'; end if;
  v_credit := round(greatest(0,v_return_gross-(coalesce(v_original.discount_amount,0)*v_return_gross/v_original_subtotal)),2);
  v_replacement_value := round(v_replacement_value,2);
  v_shipping := case when v_req.return_shipping_payer='store' then 0 else coalesce(v_original.shipping_fee,0) end;
  return json_build_object('success',true,'quantity',v_units,'original_value',v_credit,
    'replacement_value',v_replacement_value,'price_difference',round(v_replacement_value-v_credit,2),
    'shipping_fee',v_shipping,'net_settlement_amount',round(v_replacement_value-v_credit,2),
    'customer_due',greatest(round(v_replacement_value-v_credit,2),0),
    'store_refund',greatest(round(v_credit-v_replacement_value,2),0));
end;
$function$;
revoke all on function public.customer_preview_exchange_replacement_items(bigint,jsonb) from public,anon;
grant execute on function public.customer_preview_exchange_replacement_items(bigint,jsonb) to authenticated;
