do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.admin_complete_return_exchange(bigint,bigint,text)'::regprocedure);
 v_def:=replace(v_def,
   'shipping_payment_status=case when v_shipping>0 then ''unpaid'' else ''approved'' end,',
   'shipping_payment_status=case when v_shipping>0 then ''unpaid'' else ''approved'' end,');
 v_def:=replace(v_def,
   'shipping_payment_review_notes=case when v_shipping>0 then null else ''شحن الاستبدال على المتجر'' end',
   'shipping_payment_review_notes=case when v_shipping>0 then null else ''شحن الاستبدال على المتجر'' end');
 execute v_def;
end $$;
