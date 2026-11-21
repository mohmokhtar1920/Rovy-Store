do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.admin_list_orders(text)'::regprocedure);
 if position('is_exchange_replacement' in v_def)=0 then
  v_def:=replace(v_def,
   'o.shipping_fee,o.total_price,o.status,o.created_at,o.discount_amount,',
   'o.shipping_fee,o.total_price,o.status,o.created_at,o.discount_amount,'
   ||'o.is_exchange_replacement,o.exchange_return_request_id,o.exchange_credit_amount,o.exchange_price_difference,');
  execute v_def;
 end if;
end $$;
