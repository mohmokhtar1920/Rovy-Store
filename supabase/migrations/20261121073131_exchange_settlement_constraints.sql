alter table private.return_requests
 add constraint return_requests_exchange_settlement_by_fkey
 foreign key (exchange_difference_settled_by) references auth.users(id) on delete set null,
 add constraint return_requests_exchange_values_nonnegative
 check (exchange_original_value>=0 and exchange_replacement_value>=0 and exchange_shipping_fee>=0),
 add constraint return_requests_exchange_method_check
 check (exchange_difference_payment_method is null or exchange_difference_payment_method in ('cash','vodafone_cash','instapay','bank_transfer','none'));

create index if not exists idx_return_requests_exchange_settled_by
 on private.return_requests(exchange_difference_settled_by);

alter table public.orders
 add constraint orders_exchange_credit_nonnegative check (exchange_credit_amount>=0),
 add constraint orders_exchange_link_consistency
 check ((is_exchange_replacement=false and exchange_return_request_id is null)
     or (is_exchange_replacement=true and exchange_return_request_id is not null));

do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.admin_complete_return_exchange(bigint,bigint,text)'::regprocedure);
 v_def:=replace(v_def,'v_new.shipping_fee=v_shipping',
  'v_new.shipping_payment_required and v_new.shipping_fee=v_shipping');
 execute v_def;
end $$;
