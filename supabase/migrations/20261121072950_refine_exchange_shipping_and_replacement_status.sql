do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.admin_complete_return_exchange(bigint,bigint,text)'::regprocedure);
 v_def:=replace(v_def,
   'shipping_payment_status=case when v_shipping=0 then ''approved'' when v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then ''approved'' else ''unpaid'' end,',
   'shipping_payment_status=case when v_shipping=0 then ''approved'' when v_new.shipping_fee=v_shipping then v_new.shipping_payment_status else ''unpaid'' end,');
 v_def:=replace(v_def,
   'shipping_payment_method=case when v_shipping>0 and v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then v_new.shipping_payment_method else null end,',
   'shipping_payment_method=case when v_shipping>0 and v_new.shipping_fee=v_shipping then v_new.shipping_payment_method else null end,');
 v_def:=replace(v_def,
   'shipping_payment_proof_path=case when v_shipping>0 and v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then v_new.shipping_payment_proof_path else null end,',
   'shipping_payment_proof_path=case when v_shipping>0 and v_new.shipping_fee=v_shipping then v_new.shipping_payment_proof_path else null end,');
 v_def:=replace(v_def,
   'shipping_payment_submitted_at=case when v_shipping>0 and v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then v_new.shipping_payment_submitted_at else null end,',
   'shipping_payment_submitted_at=case when v_shipping>0 and v_new.shipping_fee=v_shipping then v_new.shipping_payment_submitted_at else null end,');
 v_def:=replace(v_def,
   'shipping_payment_reviewed_at=case when v_shipping=0 then now() when v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then v_new.shipping_payment_reviewed_at else null end,',
   'shipping_payment_reviewed_at=case when v_shipping=0 then now() when v_new.shipping_fee=v_shipping then v_new.shipping_payment_reviewed_at else null end,');
 v_def:=replace(v_def,
   'shipping_payment_reviewed_by=case when v_shipping=0 then auth.uid() when v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then v_new.shipping_payment_reviewed_by else null end,',
   'shipping_payment_reviewed_by=case when v_shipping=0 then auth.uid() when v_new.shipping_fee=v_shipping then v_new.shipping_payment_reviewed_by else null end,');
 v_def:=replace(v_def,
   'shipping_payment_review_notes=case when v_shipping=0 then ''شحن الاستبدال على المتجر'' when v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then v_new.shipping_payment_review_notes else null end',
   'shipping_payment_review_notes=case when v_shipping=0 then ''شحن الاستبدال على المتجر'' when v_new.shipping_fee=v_shipping then v_new.shipping_payment_review_notes else null end');
 if position('لا يحتوي طلب البديل على منتجات' in v_def)=0 then
  v_def:=replace(v_def,
   'select coalesce(sum(oi.price*oi.quantity),0)-coalesce(v_new.discount_amount,0)',
   'if not exists(select 1 from public.order_items oi where oi.order_id=p_replacement_order_id) then raise exception ''لا يحتوي طلب البديل على منتجات''; end if;'||chr(10)||
   ' select coalesce(sum(oi.price*oi.quantity),0)-coalesce(v_new.discount_amount,0)');
 end if;
 execute v_def;
end $$;

create or replace function public.admin_list_return_requests()
returns json language plpgsql security definer set search_path=''
as $function$
declare v_role text:=public.current_staff_role(); v_result json;
begin
 if auth.uid() is null or coalesce(v_role,'') not in ('owner','manager','customer_service','shipping') then raise exception 'Access denied'; end if;
 select coalesce(json_agg(row_to_json(x) order by x.created_at desc),'[]'::json) into v_result
 from (
  select r.id,r.order_id,r.customer_user_id,r.request_type,r.reason,r.details,r.status,
   r.return_shipping_payer,r.return_tracking_number,r.reviewed_at,r.review_notes,
   r.received_at,r.inspected_at,r.inspection_notes,r.refund_amount,r.refund_payment_method,
   r.refund_payment_reference,r.refund_paid_at,r.replacement_order_id,r.created_at,
   r.exchange_original_value,r.exchange_replacement_value,r.exchange_price_difference,
   r.exchange_shipping_fee,r.exchange_difference_status,r.exchange_difference_payment_method,
   r.exchange_difference_reference,r.exchange_difference_settled_at,
   o.customer_name,o.customer_phone,o.customer_address,o.delivered_at,
   replacement.status as replacement_order_status,
   coalesce((select json_agg(json_build_object('id',i.id,'order_item_id',i.order_item_id,
    'product_id',i.product_id,'product_name',i.product_name_snapshot,'size',i.size,'color',i.color,
    'unit_price',i.unit_price,'requested_quantity',i.requested_quantity,
    'accepted_quantity',i.accepted_quantity,'restocked_quantity',i.restocked_quantity,
    'inspection_note',i.inspection_note) order by i.id)
    from private.return_request_items i where i.return_request_id=r.id),'[]'::json) items
  from private.return_requests r join public.orders o on o.id=r.order_id
  left join public.orders replacement on replacement.id=r.replacement_order_id
 ) x;
 return v_result;
end;
$function$;

create or replace function public.customer_list_return_requests()
returns json language plpgsql security definer set search_path=''
as $function$
declare v_uid uuid:=auth.uid(); v_result json;
begin
 if v_uid is null then raise exception 'يجب تسجيل الدخول'; end if;
 select coalesce(json_agg(row_to_json(x) order by x.created_at desc),'[]'::json) into v_result
 from (
  select r.id,r.order_id,r.request_type,r.reason,r.details,r.status,r.return_shipping_payer,
   r.return_tracking_number,r.review_notes,r.inspection_notes,r.refund_amount,r.refund_payment_method,
   r.refund_payment_reference,r.refund_paid_at,r.replacement_order_id,r.created_at,r.updated_at,
   r.exchange_original_value,r.exchange_replacement_value,r.exchange_price_difference,
   r.exchange_shipping_fee,r.exchange_difference_status,r.exchange_difference_payment_method,
   r.exchange_difference_reference,r.exchange_difference_settled_at,
   replacement.status as replacement_order_status,
   coalesce((select json_agg(json_build_object('id',i.id,'order_item_id',i.order_item_id,
    'product_name',i.product_name_snapshot,'size',i.size,'color',i.color,
    'requested_quantity',i.requested_quantity,'accepted_quantity',i.accepted_quantity,
    'unit_price',i.unit_price) order by i.id)
    from private.return_request_items i where i.return_request_id=r.id),'[]'::json) items
  from private.return_requests r
  left join public.orders replacement on replacement.id=r.replacement_order_id
  where r.customer_user_id=v_uid
 ) x;
 return v_result;
end;
$function$;

revoke all on function public.admin_list_return_requests() from public,anon;
grant execute on function public.admin_list_return_requests() to authenticated;
revoke all on function public.customer_list_return_requests() from public,anon;
grant execute on function public.customer_list_return_requests() to authenticated;
