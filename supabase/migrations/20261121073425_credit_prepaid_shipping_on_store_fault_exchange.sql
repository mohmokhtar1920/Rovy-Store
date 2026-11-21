alter table private.return_requests
 add column if not exists exchange_prepaid_shipping_credit numeric(12,2) not null default 0,
 add column if not exists exchange_net_settlement_amount numeric(12,2) not null default 0,
 add column if not exists exchange_prepaid_shipping_method text,
 add column if not exists exchange_prepaid_shipping_proof_path text,
 add column if not exists exchange_prepaid_shipping_submitted_at timestamptz;

alter table public.orders
 add column if not exists exchange_prepaid_shipping_credit numeric(12,2) not null default 0,
 add column if not exists exchange_net_settlement_amount numeric(12,2) not null default 0;

alter table private.return_requests
 add constraint return_requests_exchange_prepaid_shipping_nonnegative check (exchange_prepaid_shipping_credit>=0),
 add constraint return_requests_exchange_prepaid_shipping_method_check
 check (exchange_prepaid_shipping_method is null or exchange_prepaid_shipping_method in ('vodafone_cash','instapay'));

alter table public.orders
 add constraint orders_exchange_prepaid_shipping_nonnegative check (exchange_prepaid_shipping_credit>=0);

create or replace function public.admin_complete_return_exchange(
 p_request_id bigint, p_replacement_order_id bigint, p_notes text default null
) returns json
language plpgsql security definer set search_path=''
as $function$
declare
 v_role text:=public.current_staff_role(); v_req private.return_requests%rowtype;
 v_original public.orders%rowtype; v_new public.orders%rowtype;
 v_original_subtotal numeric(12,2); v_return_gross numeric(12,2);
 v_credit numeric(12,2); v_replacement_value numeric(12,2);
 v_shipping numeric(12,2); v_difference numeric(12,2);
 v_prepaid_shipping_credit numeric(12,2):=0; v_net_difference numeric(12,2);
begin
 if auth.uid() is null or coalesce(v_role,'') not in ('owner','manager') then raise exception 'Owner or manager access required'; end if;
 select * into v_req from private.return_requests where id=p_request_id for update;
 if not found or v_req.request_type<>'exchange' or v_req.status<>'exchange_pending' then raise exception 'طلب الاستبدال غير جاهز للإتمام'; end if;
 select * into v_original from public.orders where id=v_req.order_id for share;
 select * into v_new from public.orders where id=p_replacement_order_id for update;
 if not found or v_new.id=v_req.order_id or v_new.created_at<v_req.created_at
   or v_new.customer_user_id is distinct from v_req.customer_user_id
   or v_new.status<>'pending' or v_new.is_exchange_replacement
   or v_new.exchange_return_request_id is not null then
  raise exception 'طلب البديل يجب أن يكون طلبًا جديدًا غير مؤكد لنفس العميل';
 end if;
 if not exists(select 1 from public.order_items oi where oi.order_id=p_replacement_order_id) then raise exception 'لا يحتوي طلب البديل على منتجات'; end if;
 if v_req.return_shipping_payer='store' and v_new.shipping_payment_required
    and v_new.shipping_payment_status='pending_review' and coalesce(v_new.shipping_fee,0)>0 then
  raise exception 'إيصال شحن البديل قيد المراجعة. يجب مراجعته أولاً قبل ربط طلب الاستبدال.';
 end if;
 select coalesce(sum(oi.price*oi.quantity),0) into v_original_subtotal from public.order_items oi where oi.order_id=v_req.order_id;
 select coalesce(sum(ri.accepted_quantity*ri.unit_price),0) into v_return_gross
 from private.return_request_items ri where ri.return_request_id=p_request_id and ri.accepted_quantity>0;
 if v_return_gross<=0 or v_original_subtotal<=0 then raise exception 'لا توجد قيمة منتجات مقبولة للاستبدال'; end if;
 v_credit:=round(greatest(0,v_return_gross-(coalesce(v_original.discount_amount,0)*v_return_gross/v_original_subtotal)),2);
 select coalesce(sum(oi.price*oi.quantity),0)-coalesce(v_new.discount_amount,0)
 into v_replacement_value from public.order_items oi where oi.order_id=p_replacement_order_id;
 v_replacement_value:=greatest(0,round(v_replacement_value,2));
 v_difference:=round(v_replacement_value-v_credit,2);
 v_shipping:=case when v_req.return_shipping_payer='store' then 0 else coalesce(v_original.shipping_fee,0) end;
 v_prepaid_shipping_credit:=case when v_req.return_shipping_payer='store'
   and v_new.shipping_payment_required and v_new.shipping_payment_status='approved'
   and coalesce(v_new.shipping_fee,0)>0 then v_new.shipping_fee else 0 end;
 v_net_difference:=round(v_difference-v_prepaid_shipping_credit,2);
 update public.orders set
   is_exchange_replacement=true,exchange_return_request_id=p_request_id,
   exchange_credit_amount=v_credit,exchange_price_difference=v_difference,
   exchange_prepaid_shipping_credit=v_prepaid_shipping_credit,exchange_net_settlement_amount=v_net_difference,
   total_price=greatest(v_net_difference,0)+v_shipping,shipping_fee=v_shipping,
   shipping_payment_required=(v_shipping>0),
   shipping_payment_status=case when v_shipping=0 then 'approved'
     when v_new.shipping_payment_required and v_new.shipping_fee=v_shipping then v_new.shipping_payment_status else 'unpaid' end,
   shipping_payment_method=case when v_shipping>0 and v_new.shipping_payment_required and v_new.shipping_fee=v_shipping then v_new.shipping_payment_method else null end,
   shipping_payment_proof_path=case when v_shipping>0 and v_new.shipping_payment_required and v_new.shipping_fee=v_shipping then v_new.shipping_payment_proof_path else null end,
   shipping_payment_submitted_at=case when v_shipping>0 and v_new.shipping_payment_required and v_new.shipping_fee=v_shipping then v_new.shipping_payment_submitted_at else null end,
   shipping_payment_reviewed_at=case when v_shipping=0 then now()
     when v_new.shipping_payment_required and v_new.shipping_fee=v_shipping then v_new.shipping_payment_reviewed_at else null end,
   shipping_payment_reviewed_by=case when v_shipping=0 then auth.uid()
     when v_new.shipping_payment_required and v_new.shipping_fee=v_shipping then v_new.shipping_payment_reviewed_by else null end,
   shipping_payment_review_notes=case when v_shipping=0 then 'شحن الاستبدال على المتجر'
     when v_new.shipping_payment_required and v_new.shipping_fee=v_shipping then v_new.shipping_payment_review_notes else null end
 where id=p_replacement_order_id;
 update private.return_requests set
   replacement_order_id=p_replacement_order_id,exchange_original_value=v_credit,
   exchange_replacement_value=v_replacement_value,exchange_price_difference=v_difference,
   exchange_shipping_fee=v_shipping,exchange_prepaid_shipping_credit=v_prepaid_shipping_credit,
   exchange_net_settlement_amount=v_net_difference,
   exchange_prepaid_shipping_method=case when v_prepaid_shipping_credit>0 then v_new.shipping_payment_method else null end,
   exchange_prepaid_shipping_proof_path=case when v_prepaid_shipping_credit>0 then v_new.shipping_payment_proof_path else null end,
   exchange_prepaid_shipping_submitted_at=case when v_prepaid_shipping_credit>0 then v_new.shipping_payment_submitted_at else null end,
   exchange_difference_status=case when v_net_difference>0 then 'customer_due' when v_net_difference<0 then 'store_refund_due' else 'settled' end,
   exchange_difference_payment_method=case when v_net_difference=0 then 'none' else null end,
   exchange_difference_reference=null,
   exchange_difference_settled_at=case when v_net_difference=0 then now() else null end,
   exchange_difference_settled_by=case when v_net_difference=0 then auth.uid() else null end,
   status='exchanged',updated_at=now()
 where id=p_request_id;
 insert into private.return_request_events(return_request_id,from_status,to_status,actor_user_id,note)
 values(p_request_id,'exchange_pending','exchanged',auth.uid(),
   concat('طلب البديل #',p_replacement_order_id,' | رصيد المرتجع ',v_credit,
   ' | قيمة البديل ',v_replacement_value,' | فرق المنتجات ',v_difference,
   ' | رصيد شحن سابق ',v_prepaid_shipping_credit,' | الصافي ',v_net_difference,
   ' | شحن البديل ',v_shipping,' | ',coalesce(p_notes,'')));
 return json_build_object('success',true,'status','exchanged','replacement_order_id',p_replacement_order_id,
   'original_value',v_credit,'replacement_value',v_replacement_value,
   'price_difference',v_difference,'prepaid_shipping_credit',v_prepaid_shipping_credit,
   'net_settlement_amount',v_net_difference,'shipping_fee',v_shipping,
   'difference_status',case when v_net_difference>0 then 'customer_due' when v_net_difference<0 then 'store_refund_due' else 'settled' end);
end;
$function$;

create or replace function public.admin_settle_exchange_difference(p_request_id bigint,p_payment_method text,p_payment_reference text)
returns json language plpgsql security definer set search_path=''
as $function$
declare v_role text:=public.current_staff_role();v_req private.return_requests%rowtype;v_order public.orders%rowtype;
begin
 if auth.uid() is null or coalesce(v_role,'') not in ('owner','manager') then raise exception 'Owner or manager access required'; end if;
 select * into v_req from private.return_requests where id=p_request_id for update;
 if not found or v_req.status<>'exchanged' or v_req.exchange_difference_status not in ('customer_due','store_refund_due') then raise exception 'لا يوجد فرق سعر مفتوح للتسوية'; end if;
 select * into v_order from public.orders where id=v_req.replacement_order_id for update;
 if not found or v_order.status<>'delivered' then raise exception 'لا تتم تسوية فرق السعر إلا بعد تسليم البديل للعميل'; end if;
 if p_payment_method not in ('cash','vodafone_cash','instapay','bank_transfer') then raise exception 'طريقة التسوية غير صحيحة'; end if;
 if nullif(btrim(coalesce(p_payment_reference,'')),'') is null then raise exception 'مرجع التحصيل أو التحويل مطلوب'; end if;
 if v_req.exchange_difference_status='store_refund_due' and p_payment_method='cash' then raise exception 'استرداد فرق السعر للعميل يجب أن يكون بتحويل موثق'; end if;
 update private.return_requests set exchange_difference_status='settled',
  exchange_difference_payment_method=p_payment_method,exchange_difference_reference=btrim(p_payment_reference),
  exchange_difference_settled_at=now(),exchange_difference_settled_by=auth.uid(),updated_at=now()
 where id=p_request_id;
 insert into private.return_request_events(return_request_id,from_status,to_status,actor_user_id,note)
 values(p_request_id,'exchanged','exchanged',auth.uid(),
  concat(case when v_req.exchange_net_settlement_amount>0 then 'تم تحصيل صافي فرق السعر' else 'تم تحويل صافي فرق السعر للعميل' end,
  ' ',abs(v_req.exchange_net_settlement_amount),' | ',p_payment_method,' | ',btrim(p_payment_reference)));
 return json_build_object('success',true,'status','settled','amount',abs(v_req.exchange_net_settlement_amount));
end;
$function$;

create or replace function public.admin_list_return_requests()
returns json language plpgsql security definer set search_path=''
as $function$
declare v_role text:=public.current_staff_role();v_result json;
begin
 if auth.uid() is null or coalesce(v_role,'') not in ('owner','manager','customer_service','shipping') then raise exception 'Access denied'; end if;
 select coalesce(json_agg(row_to_json(x) order by x.created_at desc),'[]'::json) into v_result
 from (
  select r.id,r.order_id,r.customer_user_id,r.request_type,r.reason,r.details,r.status,
   r.return_shipping_payer,r.return_tracking_number,r.reviewed_at,r.review_notes,
   r.received_at,r.inspected_at,r.inspection_notes,r.refund_amount,r.refund_payment_method,
   r.refund_payment_reference,r.refund_paid_at,r.replacement_order_id,r.created_at,
   r.exchange_original_value,r.exchange_replacement_value,r.exchange_price_difference,
   r.exchange_shipping_fee,r.exchange_prepaid_shipping_credit,r.exchange_net_settlement_amount,
   r.exchange_prepaid_shipping_method,r.exchange_difference_status,r.exchange_difference_payment_method,
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
declare v_uid uuid:=auth.uid();v_result json;
begin
 if v_uid is null then raise exception 'يجب تسجيل الدخول'; end if;
 select coalesce(json_agg(row_to_json(x) order by x.created_at desc),'[]'::json) into v_result
 from (
  select r.id,r.order_id,r.request_type,r.reason,r.details,r.status,r.return_shipping_payer,
   r.return_tracking_number,r.review_notes,r.inspection_notes,r.refund_amount,r.refund_payment_method,
   r.refund_payment_reference,r.refund_paid_at,r.replacement_order_id,r.created_at,r.updated_at,
   r.exchange_original_value,r.exchange_replacement_value,r.exchange_price_difference,
   r.exchange_shipping_fee,r.exchange_prepaid_shipping_credit,r.exchange_net_settlement_amount,
   r.exchange_difference_status,r.exchange_difference_payment_method,r.exchange_difference_reference,
   r.exchange_difference_settled_at,replacement.status as replacement_order_status,
   coalesce((select json_agg(json_build_object('id',i.id,'order_item_id',i.order_item_id,
    'product_name',i.product_name_snapshot,'size',i.size,'color',i.color,
    'requested_quantity',i.requested_quantity,'accepted_quantity',i.accepted_quantity,
    'unit_price',i.unit_price) order by i.id)
    from private.return_request_items i where i.return_request_id=r.id),'[]'::json) items
  from private.return_requests r left join public.orders replacement on replacement.id=r.replacement_order_id
  where r.customer_user_id=v_uid
 ) x;
 return v_result;
end;
$function$;

revoke all on function public.admin_complete_return_exchange(bigint,bigint,text) from public,anon;
grant execute on function public.admin_complete_return_exchange(bigint,bigint,text) to authenticated;
revoke all on function public.admin_settle_exchange_difference(bigint,text,text) from public,anon;
grant execute on function public.admin_settle_exchange_difference(bigint,text,text) to authenticated;
revoke all on function public.admin_list_return_requests() from public,anon;
grant execute on function public.admin_list_return_requests() to authenticated;
revoke all on function public.customer_list_return_requests() from public,anon;
grant execute on function public.customer_list_return_requests() to authenticated;
