do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.admin_complete_return_exchange(bigint,bigint,text)'::regprocedure);
 v_def:=replace(v_def,
   'shipping_payment_status=case when v_shipping>0 then ''unpaid'' else ''approved'' end,',
   'shipping_payment_status=case when v_shipping=0 then ''approved'' when v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then ''approved'' else ''unpaid'' end,');
 v_def:=replace(v_def,
   'shipping_payment_method=null,',
   'shipping_payment_method=case when v_shipping>0 and v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then v_new.shipping_payment_method else null end,');
 v_def:=replace(v_def,
   'shipping_payment_proof_path=null,',
   'shipping_payment_proof_path=case when v_shipping>0 and v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then v_new.shipping_payment_proof_path else null end,');
 v_def:=replace(v_def,
   'shipping_payment_submitted_at=null,',
   'shipping_payment_submitted_at=case when v_shipping>0 and v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then v_new.shipping_payment_submitted_at else null end,');
 v_def:=replace(v_def,
   'shipping_payment_reviewed_at=case when v_shipping>0 then null else now() end,',
   'shipping_payment_reviewed_at=case when v_shipping=0 then now() when v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then v_new.shipping_payment_reviewed_at else null end,');
 v_def:=replace(v_def,
   'shipping_payment_reviewed_by=case when v_shipping>0 then null else auth.uid() end,',
   'shipping_payment_reviewed_by=case when v_shipping=0 then auth.uid() when v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then v_new.shipping_payment_reviewed_by else null end,');
 v_def:=replace(v_def,
   'shipping_payment_review_notes=case when v_shipping>0 then null else ''شحن الاستبدال على المتجر'' end',
   'shipping_payment_review_notes=case when v_shipping=0 then ''شحن الاستبدال على المتجر'' when v_new.shipping_payment_status=''approved'' and v_new.shipping_fee=v_shipping then v_new.shipping_payment_review_notes else null end');
 execute v_def;
end $$;
