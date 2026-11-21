create or replace function public.customer_preview_exchange_replacement(
  p_request_id bigint,p_product_id bigint,p_variant_id bigint default null
) returns json
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid:=auth.uid();
  v_req private.return_requests%rowtype;
  v_original public.orders%rowtype;
  v_product public.products%rowtype;
  v_variant public.product_variants%rowtype;
  v_units integer;
  v_original_subtotal numeric(12,2);
  v_return_gross numeric(12,2);
  v_credit numeric(12,2);
  v_replacement_value numeric(12,2);
  v_difference numeric(12,2);
  v_shipping numeric(12,2);
begin
  if v_uid is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not exists(select 1 from auth.users u where u.id=v_uid and u.email_confirmed_at is not null) then
    raise exception 'يجب تأكيد البريد الإلكتروني أولاً';
  end if;
  select * into v_req from private.return_requests
  where id=p_request_id and customer_user_id=v_uid for share;
  if not found or v_req.request_type<>'exchange' or v_req.status<>'exchange_pending'
     or v_req.replacement_order_id is not null then raise exception 'طلب الاستبدال غير متاح للمعاينة'; end if;
  select * into v_original from public.orders where id=v_req.order_id and customer_user_id=v_uid;
  if not found then raise exception 'الطلب الأصلي غير موجود'; end if;
  select coalesce(sum(accepted_quantity),0)::integer into v_units
  from private.return_request_items where return_request_id=p_request_id and accepted_quantity>0;
  if v_units<1 then raise exception 'لا توجد قطع معتمدة للاستبدال'; end if;
  select * into v_product from public.products where id=p_product_id and is_active is true;
  if not found then raise exception 'المنتج غير متاح'; end if;
  if p_variant_id is not null then
    select * into v_variant from public.product_variants
    where id=p_variant_id and product_id=p_product_id and stock>=v_units;
    if not found then raise exception 'المقاس أو اللون غير متاح بالكمية المطلوبة'; end if;
  else
    if exists(select 1 from public.product_variants where product_id=p_product_id) then raise exception 'يجب اختيار المقاس واللون'; end if;
    if coalesce(v_product.stock,0)<v_units then raise exception 'الكمية المطلوبة غير متاحة'; end if;
  end if;
  select coalesce(sum(price*quantity),0) into v_original_subtotal from public.order_items where order_id=v_req.order_id;
  select coalesce(sum(accepted_quantity*unit_price),0) into v_return_gross
  from private.return_request_items where return_request_id=p_request_id and accepted_quantity>0;
  if v_original_subtotal<=0 or v_return_gross<=0 then raise exception 'تعذر حساب رصيد الاستبدال'; end if;
  v_credit:=round(greatest(0,v_return_gross-(coalesce(v_original.discount_amount,0)*v_return_gross/v_original_subtotal)),2);
  v_replacement_value:=round(v_product.price*v_units,2);
  v_difference:=round(v_replacement_value-v_credit,2);
  v_shipping:=case when v_req.return_shipping_payer='store' then 0 else coalesce(v_original.shipping_fee,0) end;
  return json_build_object('success',true,'quantity',v_units,'original_value',v_credit,
    'replacement_value',v_replacement_value,'price_difference',v_difference,'shipping_fee',v_shipping,
    'net_settlement_amount',v_difference,'customer_due',greatest(v_difference,0),'store_refund',greatest(-v_difference,0));
end;
$function$;
revoke all on function public.customer_preview_exchange_replacement(bigint,bigint,bigint) from public,anon;
grant execute on function public.customer_preview_exchange_replacement(bigint,bigint,bigint) to authenticated;
