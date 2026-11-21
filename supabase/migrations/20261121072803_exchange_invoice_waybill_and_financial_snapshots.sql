do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.admin_issue_store_invoice(bigint,text)'::regprocedure);
 if position('is_exchange_replacement' in v_def)=0 then
  v_def:=replace(v_def,
   '''shipping_payment_method'',v_order.shipping_payment_method,',
   '''shipping_payment_method'',v_order.shipping_payment_method,
    ''is_exchange_replacement'',v_order.is_exchange_replacement,
    ''exchange_credit_amount'',v_order.exchange_credit_amount,
    ''exchange_price_difference'',v_order.exchange_price_difference,
    ''exchange_return_request_id'',v_order.exchange_return_request_id,');
  execute v_def;
 end if;
 v_def:=pg_get_functiondef('public.admin_issue_store_waybill(bigint)'::regprocedure);
 if position('is_exchange_replacement' in v_def)=0 then
  v_def:=replace(v_def,
   '''order_total'',coalesce(v_order.total_price,0),',
   '''order_total'',coalesce(v_order.total_price,0),
    ''is_exchange_replacement'',v_order.is_exchange_replacement,
    ''exchange_credit_amount'',v_order.exchange_credit_amount,
    ''exchange_price_difference'',v_order.exchange_price_difference,
    ''exchange_return_request_id'',v_order.exchange_return_request_id,');
  execute v_def;
 end if;
 v_def:=pg_get_functiondef('public.admin_financial_summary()'::regprocedure);
 if position('exchange_credit_amount' in v_def)=0 then
  v_def:=replace(v_def,
   'coalesce(sum(greatest(0,price*quantity-case when items_subtotal>0 then discount_amount*(price*quantity/items_subtotal) else 0 end)),0) revenue,',
   'coalesce(sum(greatest(0,price*quantity-case when items_subtotal>0 then discount_amount*(price*quantity/items_subtotal) else 0 end)),0)
    - coalesce((select sum(o.exchange_credit_amount) from public.orders o where o.status=''delivered'' and o.is_exchange_replacement),0) revenue,');
  v_def:=replace(v_def,
   'coalesce(sum(coalesce(purchase_price_snapshot,0)*quantity),0) cost,',
   'coalesce(sum(coalesce(purchase_price_snapshot,0)*quantity),0)
    - coalesce((select sum(ri.accepted_quantity*oic.purchase_price_snapshot)
      from private.return_requests rr join private.return_request_items ri on ri.return_request_id=rr.id
      join private.order_item_costs oic on oic.order_item_id=ri.order_item_id
      join public.orders ro on ro.id=rr.replacement_order_id
      where rr.request_type=''exchange'' and rr.status=''exchanged'' and ro.status=''delivered'' and ri.accepted_quantity>0),0) cost,');
  v_def:=replace(v_def,
   'coalesce(sum(quantity),0)::bigint units from delivered_lines',
   'greatest(0,coalesce(sum(quantity),0)::bigint - coalesce((select sum(ri.accepted_quantity)::bigint
      from private.return_requests rr join private.return_request_items ri on ri.return_request_id=rr.id
      join public.orders ro on ro.id=rr.replacement_order_id
      where rr.request_type=''exchange'' and rr.status=''exchanged'' and ro.status=''delivered''),0))::bigint units from delivered_lines');
  execute v_def;
 end if;
end $$;
