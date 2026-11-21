do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.admin_issue_store_invoice(bigint,text)'::regprocedure);
 v_def:=replace(v_def,
  '''gross_profit'',case when v_missing_costs=0 then v_subtotal-coalesce(v_order.discount_amount,0)-v_cost_total else null end,',
  '''gross_profit'',case when v_missing_costs=0 then v_subtotal-coalesce(v_order.discount_amount,0)-coalesce(v_order.exchange_credit_amount,0)-v_cost_total else null end,');
 execute v_def;
end $$;
