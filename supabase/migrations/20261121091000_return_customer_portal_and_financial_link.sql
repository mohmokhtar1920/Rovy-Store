CREATE OR REPLACE FUNCTION public.customer_list_return_eligible_orders()
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_uid uuid:=auth.uid(); v_result json;
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'يجب تسجيل الدخول'; END IF;
 SELECT coalesce(json_agg(row_to_json(x) ORDER BY x.delivered_at DESC),'[]'::json) INTO v_result
 FROM (
  SELECT o.id AS order_id,o.delivered_at,
   coalesce((SELECT json_agg(json_build_object(
     'order_item_id',oi.id,'product_id',oi.product_id,
     'product_name',coalesce(p.name,'منتج'),'image_url',p.image_url,
     'size',oi.size,'color',oi.color,'unit_price',oi.price,
     'purchased_quantity',oi.quantity,
     'remaining_quantity',greatest(oi.quantity-coalesce((
       SELECT sum(ri.requested_quantity) FROM private.return_request_items ri
       JOIN private.return_requests rr ON rr.id=ri.return_request_id
       WHERE ri.order_item_id=oi.id AND rr.status<>'rejected'
     ),0),0)
   ) ORDER BY oi.id)
   FROM public.order_items oi LEFT JOIN public.products p ON p.id=oi.product_id
   WHERE oi.order_id=o.id
     AND oi.quantity>coalesce((SELECT sum(ri.requested_quantity) FROM private.return_request_items ri
       JOIN private.return_requests rr ON rr.id=ri.return_request_id
       WHERE ri.order_item_id=oi.id AND rr.status<>'rejected'),0)
   ),'[]'::json) AS items
  FROM public.orders o
  WHERE o.customer_user_id=v_uid AND o.status='delivered'
    AND o.delivered_at IS NOT NULL AND now()<=o.delivered_at+interval '14 days'
    AND EXISTS(SELECT 1 FROM public.order_items oi WHERE oi.order_id=o.id
      AND oi.quantity>coalesce((SELECT sum(ri.requested_quantity) FROM private.return_request_items ri
        JOIN private.return_requests rr ON rr.id=ri.return_request_id
        WHERE ri.order_item_id=oi.id AND rr.status<>'rejected'),0))
    AND NOT EXISTS(SELECT 1 FROM private.return_requests r WHERE r.order_id=o.id
      AND r.status IN ('submitted','approved','in_transit','received','inspected','refund_approved','exchange_pending'))
 ) x;
 RETURN v_result;
END; $function$;
REVOKE ALL ON FUNCTION public.customer_list_return_eligible_orders() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.customer_list_return_eligible_orders() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_mark_return_refund_paid(
 p_request_id bigint,p_payment_method text,p_payment_reference text
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_role text:=public.current_staff_role(); v_req private.return_requests%rowtype;
BEGIN
 IF auth.uid() IS NULL OR coalesce(v_role,'') NOT IN ('owner','manager') THEN RAISE EXCEPTION 'Owner or manager access required'; END IF;
 IF p_payment_method NOT IN ('vodafone_cash','instapay','bank_transfer','cash') THEN RAISE EXCEPTION 'طريقة الاسترداد غير صحيحة'; END IF;
 IF nullif(btrim(coalesce(p_payment_reference,'')),'') IS NULL THEN RAISE EXCEPTION 'أدخل مرجع التحويل أو إثبات التنفيذ'; END IF;
 SELECT * INTO v_req FROM private.return_requests WHERE id=p_request_id FOR UPDATE;
 IF NOT FOUND OR v_req.status<>'refund_approved' THEN RAISE EXCEPTION 'يجب اعتماد الاسترداد أولاً'; END IF;
 UPDATE private.return_requests SET status='refunded',refund_payment_method=p_payment_method,
  refund_payment_reference=btrim(p_payment_reference),refund_paid_by=auth.uid(),refund_paid_at=now(),updated_at=now()
 WHERE id=p_request_id;
 INSERT INTO private.store_expenses(expense_date,category,description,amount,created_by)
 VALUES(current_date,'استرداد عميل','استرداد طلب مرتجع رقم #'||v_req.id||' للطلب #'||v_req.order_id||' - '||btrim(p_payment_reference),v_req.refund_amount,auth.uid());
 INSERT INTO private.return_request_events(return_request_id,from_status,to_status,actor_user_id,note)
 VALUES(p_request_id,'refund_approved','refunded',auth.uid(),'تم تسجيل تنفيذ الاسترداد: '||btrim(p_payment_reference));
 RETURN json_build_object('success',true,'status','refunded','amount',v_req.refund_amount);
END; $function$;
REVOKE ALL ON FUNCTION public.admin_mark_return_refund_paid(bigint,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_mark_return_refund_paid(bigint,text,text) TO authenticated;