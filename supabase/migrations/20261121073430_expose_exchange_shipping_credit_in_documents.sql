do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.admin_issue_store_invoice(bigint,text)'::regprocedure);
 v_def:=replace(v_def,
  '''exchange_price_difference'',v_order.exchange_price_difference,',
  '''exchange_price_difference'',v_order.exchange_price_difference,
    ''exchange_prepaid_shipping_credit'',v_order.exchange_prepaid_shipping_credit,
    ''exchange_net_settlement_amount'',v_order.exchange_net_settlement_amount,');
 execute v_def;
 v_def:=pg_get_functiondef('public.admin_issue_store_waybill(bigint)'::regprocedure);
 v_def:=replace(v_def,
  '''exchange_price_difference'',v_order.exchange_price_difference,',
  '''exchange_price_difference'',v_order.exchange_price_difference,
    ''exchange_prepaid_shipping_credit'',v_order.exchange_prepaid_shipping_credit,
    ''exchange_net_settlement_amount'',v_order.exchange_net_settlement_amount,');
 execute v_def;
 v_def:=pg_get_functiondef('public.admin_list_orders(text)'::regprocedure);
 v_def:=replace(v_def,
  'o.exchange_credit_amount,o.exchange_price_difference,',
  'o.exchange_credit_amount,o.exchange_price_difference,o.exchange_prepaid_shipping_credit,o.exchange_net_settlement_amount,');
 execute v_def;
end $$;
