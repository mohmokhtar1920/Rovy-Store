ALTER TABLE private.return_requests DROP CONSTRAINT IF EXISTS return_requests_reason_check;
ALTER TABLE private.return_requests ADD CONSTRAINT return_requests_reason_check
CHECK(reason IN ('wrong_size','wrong_size_sent','defective','damaged','not_as_described','changed_mind','other'));

CREATE OR REPLACE FUNCTION public.customer_create_return_request(
 p_order_id bigint,p_request_type text,p_reason text,p_details text,p_items jsonb
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_uid uuid:=auth.uid(); v_order public.orders%rowtype; v_request_id bigint;
 v_item jsonb; v_order_item public.order_items%rowtype; v_qty integer; v_prev integer; v_name text; v_payer text;
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'يجب تسجيل الدخول أولاً'; END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=v_uid AND u.email_confirmed_at IS NOT NULL) THEN RAISE EXCEPTION 'يجب تأكيد البريد الإلكتروني أولاً'; END IF;
 IF p_request_type NOT IN ('return','exchange') THEN RAISE EXCEPTION 'نوع الطلب غير صحيح'; END IF;
 IF p_reason NOT IN ('wrong_size','wrong_size_sent','defective','damaged','not_as_described','changed_mind','other') THEN RAISE EXCEPTION 'سبب الطلب غير صحيح'; END IF;
 IF p_items IS NULL OR jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)<1 OR jsonb_array_length(p_items)>30 THEN RAISE EXCEPTION 'اختر منتجاً واحداً على الأقل'; END IF;
 IF length(coalesce(p_details,''))>1500 THEN RAISE EXCEPTION 'التفاصيل طويلة جداً'; END IF;
 SELECT * INTO v_order FROM public.orders WHERE id=p_order_id AND customer_user_id=v_uid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'الطلب غير موجود في حسابك'; END IF;
 IF v_order.status<>'delivered' OR v_order.delivered_at IS NULL THEN RAISE EXCEPTION 'يمكن طلب الاسترجاع أو الاستبدال بعد استلام الطلب فقط'; END IF;
 IF now()>v_order.delivered_at+interval '14 days' THEN RAISE EXCEPTION 'انتهت مهلة الاسترجاع والاستبدال (14 يوماً من الاستلام)'; END IF;
 IF EXISTS(SELECT 1 FROM private.return_requests r WHERE r.order_id=p_order_id AND r.status IN ('submitted','approved','in_transit','received','inspected','refund_approved','exchange_pending')) THEN RAISE EXCEPTION 'يوجد بالفعل طلب استرجاع أو استبدال مفتوح لهذا الطلب'; END IF;
 v_payer:=CASE WHEN p_reason IN ('wrong_size_sent','defective','damaged','not_as_described') THEN 'store' ELSE 'customer' END;
 INSERT INTO private.return_requests(order_id,customer_user_id,request_type,reason,details,return_shipping_payer)
 VALUES(p_order_id,v_uid,p_request_type,p_reason,nullif(btrim(coalesce(p_details,'')),''),v_payer) RETURNING id INTO v_request_id;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
  IF nullif(v_item->>'order_item_id','') IS NULL OR nullif(v_item->>'quantity','') IS NULL THEN RAISE EXCEPTION 'بيانات المنتج المختار غير مكتملة'; END IF;
  SELECT * INTO v_order_item FROM public.order_items WHERE id=(v_item->>'order_item_id')::bigint AND order_id=p_order_id FOR UPDATE;
  IF NOT FOUND OR v_order_item.product_id IS NULL THEN RAISE EXCEPTION 'المنتج غير تابع لهذا الطلب'; END IF;
  v_qty:=(v_item->>'quantity')::integer;
  IF v_qty<1 OR v_qty>v_order_item.quantity THEN RAISE EXCEPTION 'الكمية المطلوبة غير صحيحة'; END IF;
  SELECT coalesce(sum(ri.requested_quantity),0)::integer INTO v_prev FROM private.return_request_items ri JOIN private.return_requests rr ON rr.id=ri.return_request_id WHERE ri.order_item_id=v_order_item.id AND rr.status<>'rejected';
  IF v_qty+v_prev>v_order_item.quantity THEN RAISE EXCEPTION 'الكمية المطلوبة أكبر من الكمية المتاحة للإرجاع'; END IF;
  SELECT name INTO v_name FROM public.products WHERE id=v_order_item.product_id;
  INSERT INTO private.return_request_items(return_request_id,order_item_id,product_id,product_name_snapshot,size,color,unit_price,requested_quantity)
  VALUES(v_request_id,v_order_item.id,v_order_item.product_id,coalesce(v_name,'منتج'),v_order_item.size,v_order_item.color,v_order_item.price,v_qty);
 END LOOP;
 IF NOT EXISTS(SELECT 1 FROM private.return_request_items WHERE return_request_id=v_request_id) THEN RAISE EXCEPTION 'لم يتم اختيار منتجات صالحة'; END IF;
 INSERT INTO private.return_request_events(return_request_id,from_status,to_status,actor_user_id,note) VALUES(v_request_id,NULL,'submitted',v_uid,'طلب العميل عبر الموقع');
 RETURN json_build_object('success',true,'return_request_id',v_request_id,'status','submitted','return_shipping_payer',v_payer);
END; $function$;
REVOKE ALL ON FUNCTION public.customer_create_return_request(bigint,text,text,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.customer_create_return_request(bigint,text,text,text,jsonb) TO authenticated;