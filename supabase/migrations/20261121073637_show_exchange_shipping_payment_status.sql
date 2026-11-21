alter table private.return_requests
 add column if not exists exchange_shipping_payment_status text not null default 'not_required',
 add column if not exists exchange_shipping_payment_method text;

alter table private.return_requests
 add constraint return_requests_exchange_shipping_payment_status_check
 check (exchange_shipping_payment_status in ('not_required','unpaid','pending_review','approved','rejected')),
 add constraint return_requests_exchange_shipping_payment_method_check
 check (exchange_shipping_payment_method is null or exchange_shipping_payment_method in ('vodafone_cash','instapay'));

do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.admin_complete_return_exchange(bigint,bigint,text)'::regprocedure);
 v_def:=replace(v_def,
  '   exchange_prepaid_shipping_submitted_at=case when v_prepaid_shipping_credit>0 then v_new.shipping_payment_submitted_at else null end,',
  '   exchange_prepaid_shipping_submitted_at=case when v_prepaid_shipping_credit>0 then v_new.shipping_payment_submitted_at else null end,'||chr(10)||
  '   exchange_shipping_payment_status=case when v_shipping=0 then ''not_required'' when v_new.shipping_payment_required and v_new.shipping_fee=v_shipping then v_new.shipping_payment_status else ''unpaid'' end,'||chr(10)||
  '   exchange_shipping_payment_method=case when v_shipping>0 and v_new.shipping_payment_required and v_new.shipping_fee=v_shipping then v_new.shipping_payment_method else null end,');
 execute v_def;
 v_def:=pg_get_functiondef('public.admin_list_return_requests()'::regprocedure);
 v_def:=replace(v_def,
  'r.exchange_prepaid_shipping_method,r.exchange_difference_status,',
  'r.exchange_prepaid_shipping_method,r.exchange_shipping_payment_status,r.exchange_shipping_payment_method,r.exchange_difference_status,');
 execute v_def;
 v_def:=pg_get_functiondef('public.customer_list_return_requests()'::regprocedure);
 v_def:=replace(v_def,
  'r.exchange_shipping_fee,r.exchange_prepaid_shipping_credit,r.exchange_net_settlement_amount,',
  'r.exchange_shipping_fee,r.exchange_prepaid_shipping_credit,r.exchange_net_settlement_amount,r.exchange_shipping_payment_status,r.exchange_shipping_payment_method,');
 execute v_def;
end $$;
