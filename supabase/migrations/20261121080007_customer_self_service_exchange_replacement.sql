create or replace function public.customer_create_exchange_replacement(
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
  v_created json;
  v_new_id bigint;
  v_units integer;
  v_requested_units integer;
  v_original_subtotal numeric(12,2);
  v_return_gross numeric(12,2);
  v_credit numeric(12,2);
  v_replacement_value numeric(12,2);
  v_difference numeric(12,2);
  v_shipping numeric(12,2);
begin
  if v_uid is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not exists (select 1 from auth.users u where u.id=v_uid and u.email_confirmed_at is not null) then
    raise exception 'يجب تأكيد البريد الإلكتروني أولاً';
  end if;
  select * into v_req from private.return_requests
  where id=p_request_id and customer_user_id=v_uid for update;
  if not found or v_req.request_type<>'exchange' or v_req.status<>'exchange_pending'
     or v_req.replacement_order_id is not null then
    raise exception 'طلب الاستبدال غير جاهز لاختيار المنتج البديل';
  end if;
  select * into v_original from public.orders
  where id=v_req.order_id and customer_user_id=v_uid for share;
  if not found or v_original.status<>'delivered' then raise exception 'تعذر التحقق من الطلب الأصلي'; end if;
  select coalesce(sum(accepted_quantity),0)::integer into v_units
  from private.return_request_items where return_request_id=p_request_id and accepted_quantity>0;
  if v_units<1 then raise exception 'لم يتم اعتماد أي قطعة للاستبدال بعد الفحص'; end if;
  if p_items is null or pg_catalog.jsonb_typeof(p_items)<>'array'
     or pg_catalog.jsonb_array_length(p_items)<1 or pg_catalog.jsonb_array_length(p_items)>30 then
    raise exception 'اختيارات المنتجات غير صحيحة';
  end if;
  select coalesce(sum((x.value->>'quantity')::integer),0)::integer into v_requested_units
  from pg_catalog.jsonb_array_elements(p_items) x(value);
  if v_requested_units<>v_units then raise exception 'يجب اختيار نفس عدد القطع التي تم اعتمادها للاستبدال'; end if;
  select coalesce(sum(oi.price*oi.quantity),0) into v_original_subtotal
  from public.order_items oi where oi.order_id=v_req.order_id;
  select coalesce(sum(ri.accepted_quantity*ri.unit_price),0) into v_return_gross
  from private.return_request_items ri where ri.return_request_id=p_request_id and ri.accepted_quantity>0;
  if v_original_subtotal<=0 or v_return_gross<=0 then raise exception 'تعذر حساب قيمة المنتجات المعتمدة للاستبدال'; end if;
  v_credit:=round(greatest(0,v_return_gross-(coalesce(v_original.discount_amount,0)*v_return_gross/v_original_subtotal)),2);
  v_created:=public.create_order_secure(v_original.customer_name,v_original.customer_phone,v_original.customer_address,p_items,null);
  v_new_id:=(v_created->>'order_id')::bigint;
  select coalesce(sum(oi.price*oi.quantity),0) into v_replacement_value
  from public.order_items oi where oi.order_id=v_new_id;
  v_replacement_value:=round(greatest(0,v_replacement_value),2);
  v_difference:=round(v_replacement_value-v_credit,2);
  v_shipping:=case when v_req.return_shipping_payer='store' then 0 else coalesce(v_original.shipping_fee,0) end;
  update public.orders set
    is_exchange_replacement=true,exchange_return_request_id=p_request_id,
    exchange_credit_amount=v_credit,exchange_price_difference=v_difference,
    exchange_prepaid_shipping_credit=0,exchange_net_settlement_amount=v_difference,
    total_price=greatest(v_difference,0)+v_shipping,
    governorate_id=v_original.governorate_id,governorate_name=v_original.governorate_name,
    shipping_fee=v_shipping,shipping_payment_required=(v_shipping>0),
    shipping_payment_status=case when v_shipping>0 then 'unpaid' else 'approved' end,
    shipping_payment_method=null,shipping_payment_proof_path=null,shipping_payment_submitted_at=null,
    shipping_payment_reviewed_at=case when v_shipping=0 then now() else null end,
    shipping_payment_reviewed_by=case when v_shipping=0 then v_uid else null end,
    shipping_payment_review_notes=case when v_shipping=0 then 'شحن الاستبدال على المتجر' else null end,
    shipping_company_id=null,shipping_tracking_number=null,shipping_cod_due=null,shipping_company_fee=0
  where id=v_new_id and customer_user_id=v_uid;
  update private.return_requests set
    replacement_order_id=v_new_id,exchange_original_value=v_credit,
    exchange_replacement_value=v_replacement_value,exchange_price_difference=v_difference,
    exchange_shipping_fee=v_shipping,exchange_prepaid_shipping_credit=0,
    exchange_net_settlement_amount=v_difference,exchange_prepaid_shipping_method=null,
    exchange_prepaid_shipping_proof_path=null,exchange_prepaid_shipping_submitted_at=null,
    exchange_shipping_payment_status=case when v_shipping>0 then 'unpaid' else 'not_required' end,
    exchange_shipping_payment_method=null,
    exchange_difference_status=case when v_difference>0 then 'customer_due' when v_difference<0 then 'store_refund_due' else 'settled' end,
    exchange_difference_payment_method=case when v_difference=0 then 'none' else null end,
    exchange_difference_reference=null,
    exchange_difference_settled_at=case when v_difference=0 then now() else null end,
    exchange_difference_settled_by=case when v_difference=0 then v_uid else null end,
    status='exchanged',updated_at=now()
  where id=p_request_id;
  insert into private.return_request_events(return_request_id,from_status,to_status,actor_user_id,note)
  values(p_request_id,'exchange_pending','exchanged',v_uid,
    concat('العميل اختار البديل من الموقع. طلب البديل #',v_new_id,' | رصيد المرتجع ',v_credit,
    ' | قيمة البديل ',v_replacement_value,' | فرق المنتجات ',v_difference,' | شحن البديل ',v_shipping));
  return json_build_object('success',true,'return_request_id',p_request_id,'replacement_order_id',v_new_id,
    'original_value',v_credit,'replacement_value',v_replacement_value,'price_difference',v_difference,
    'shipping_fee',v_shipping,'net_settlement_amount',v_difference,
    'difference_status',case when v_difference>0 then 'customer_due' when v_difference<0 then 'store_refund_due' else 'settled' end);
end;
$function$;
revoke all on function public.customer_create_exchange_replacement(bigint,jsonb) from public,anon;
grant execute on function public.customer_create_exchange_replacement(bigint,jsonb) to authenticated;
