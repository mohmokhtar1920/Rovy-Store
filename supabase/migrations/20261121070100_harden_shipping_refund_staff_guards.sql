
create or replace function public.admin_list_shipping_refunds()
returns json language plpgsql security definer set search_path=''
as $$
declare v_role text; v_result json;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 v_role:=public.current_staff_role();
 if coalesce(v_role,'') not in ('owner','manager') then raise exception 'Owner or manager access required'; end if;
 select coalesce(json_agg(row_to_json(x) order by x.created_at desc),'[]'::json) into v_result
 from (select r.id,r.order_id,r.amount,r.status,r.reason,r.payment_method,r.payment_reference,r.payment_proof_path,
       r.created_at,r.reviewed_at,r.review_notes,r.paid_at,o.customer_name,o.customer_phone,o.shipping_fee,
       o.status as order_status,coalesce(sp.full_name,'') as reviewed_by_name
       from private.shipping_refunds r join public.orders o on o.id=r.order_id
       left join public.staff_profiles sp on sp.user_id=r.reviewed_by) x;
 return v_result;
end; $$;

create or replace function public.admin_review_shipping_refund(p_refund_id bigint,p_approved boolean,p_notes text default null)
returns json language plpgsql security definer set search_path=''
as $$
declare v_role text; v_refund private.shipping_refunds%rowtype;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 v_role:=public.current_staff_role();
 if coalesce(v_role,'') not in ('owner','manager') then raise exception 'Owner or manager access required'; end if;
 select * into v_refund from private.shipping_refunds where id=p_refund_id for update;
 if not found then raise exception 'Refund request not found'; end if;
 if v_refund.status<>'pending_review' then raise exception 'Refund is not awaiting review'; end if;
 if not p_approved and nullif(btrim(coalesce(p_notes,'')),'') is null then raise exception 'اكتب سبب رفض طلب الاسترداد'; end if;
 update private.shipping_refunds set status=case when p_approved then 'approved' else 'rejected' end,
   reviewed_by=auth.uid(),reviewed_at=now(),review_notes=nullif(btrim(coalesce(p_notes,'')),''),
   updated_at=now() where id=p_refund_id;
 return json_build_object('success',true,'refund_id',p_refund_id,'status',case when p_approved then 'approved' else 'rejected' end);
end; $$;

create or replace function public.admin_mark_shipping_refund_paid(p_refund_id bigint,p_payment_method text,p_payment_reference text,p_payment_proof_path text default null)
returns json language plpgsql security definer set search_path=''
as $$
declare v_role text; v_refund private.shipping_refunds%rowtype;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 v_role:=public.current_staff_role();
 if coalesce(v_role,'') not in ('owner','manager') then raise exception 'Owner or manager access required'; end if;
 if p_payment_method not in ('vodafone_cash','instapay','bank_transfer','cash') then raise exception 'طريقة الاسترداد غير صحيحة'; end if;
 if nullif(btrim(coalesce(p_payment_reference,'')),'') is null then raise exception 'أدخل رقم مرجع التحويل أو ملاحظة إثبات الدفع'; end if;
 select * into v_refund from private.shipping_refunds where id=p_refund_id for update;
 if not found then raise exception 'Refund request not found'; end if;
 if v_refund.status<>'approved' then raise exception 'يجب اعتماد طلب الاسترداد أولاً'; end if;
 update private.shipping_refunds set status='paid',payment_method=p_payment_method,payment_reference=btrim(p_payment_reference),
   payment_proof_path=nullif(btrim(coalesce(p_payment_proof_path,'')),''),paid_by=auth.uid(),paid_at=now(),updated_at=now()
   where id=p_refund_id;
 return json_build_object('success',true,'refund_id',p_refund_id,'status','paid','amount',v_refund.amount);
end; $$;
revoke all on function public.admin_list_shipping_refunds() from public,anon;
revoke all on function public.admin_review_shipping_refund(bigint,boolean,text) from public,anon;
revoke all on function public.admin_mark_shipping_refund_paid(bigint,text,text,text) from public,anon;
grant execute on function public.admin_list_shipping_refunds() to authenticated;
grant execute on function public.admin_review_shipping_refund(bigint,boolean,text) to authenticated;
grant execute on function public.admin_mark_shipping_refund_paid(bigint,text,text,text) to authenticated;
