CREATE OR REPLACE FUNCTION public.admin_inspect_return_request(p_request_id bigint,p_items jsonb,p_notes text DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE
 v_role text:=public.current_staff_role(); v_req private.return_requests%rowtype;
 v_item jsonb; v_line private.return_request_items%rowtype; v_qty integer;
 v_total numeric(12,2):=0; v_has_variants boolean;
BEGIN
 IF auth.uid() IS NULL OR coalesce(v_role,'') NOT IN ('owner','manager') THEN RAISE EXCEPTION 'Owner or manager access required'; END IF;
 SELECT * INTO v_req FROM private.return_requests WHERE id=p_request_id FOR UPDATE;
 IF NOT FOUND OR v_req.status<>'received' THEN RAISE EXCEPTION 'يجب استلام المرتجع قبل الفحص'; END IF;
 IF p_items IS NULL OR jsonb_typeof(p_items)<>'array' THEN RAISE EXCEPTION 'بيانات الفحص غير صحيحة'; END IF;
 IF jsonb_array_length(p_items)<>(SELECT count(*) FROM private.return_request_items WHERE return_request_id=p_request_id) THEN
  RAISE EXCEPTION 'يجب مراجعة كل المنتجات في طلب المرتجع';
 END IF;
 IF EXISTS(
  SELECT 1 FROM (
   SELECT (value->>'return_item_id')::bigint AS item_id,count(*) AS qty
   FROM jsonb_array_elements(p_items) GROUP BY (value->>'return_item_id')::bigint
  ) x WHERE x.qty<>1
 ) OR EXISTS(
  SELECT 1 FROM private.return_request_items ri
  WHERE ri.return_request_id=p_request_id
    AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_items) j WHERE (j->>'return_item_id')::bigint=ri.id)
 ) THEN RAISE EXCEPTION 'يجب إدخال كل بند مرة واحدة فقط'; END IF;

 FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
  SELECT * INTO v_line FROM private.return_request_items
   WHERE id=(v_item->>'return_item_id')::bigint AND return_request_id=p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'عنصر مرتجع غير صحيح'; END IF;
  IF nullif(v_item->>'accepted_quantity','') IS NULL THEN RAISE EXCEPTION 'الكمية المقبولة مطلوبة لكل منتج'; END IF;
  v_qty:=(v_item->>'accepted_quantity')::integer;
  IF v_qty<0 OR v_qty>v_line.requested_quantity THEN RAISE EXCEPTION 'الكمية المقبولة غير صحيحة'; END IF;
  IF v_qty>0 THEN
   SELECT EXISTS(SELECT 1 FROM public.product_variants WHERE product_id=v_line.product_id) INTO v_has_variants;
   IF v_line.size IS NOT NULL OR v_line.color IS NOT NULL OR v_has_variants THEN
    UPDATE public.product_variants SET stock=coalesce(stock,0)+v_qty
    WHERE product_id=v_line.product_id AND size IS NOT DISTINCT FROM v_line.size AND color IS NOT DISTINCT FROM v_line.color;
    IF NOT FOUND THEN RAISE EXCEPTION 'لم يتم العثور على نفس المقاس واللون في المخزون للمنتج: %',v_line.product_name_snapshot; END IF;
   ELSE
    UPDATE public.products SET stock=stock+v_qty WHERE id=v_line.product_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'المنتج غير موجود بالمخزون: %',v_line.product_name_snapshot; END IF;
   END IF;
  END IF;
  UPDATE private.return_request_items SET accepted_quantity=v_qty,restocked_quantity=v_qty,
   inspection_note=nullif(btrim(coalesce(v_item->>'inspection_note','')),'') WHERE id=v_line.id;
  v_total:=v_total+(v_qty*v_line.unit_price);
 END LOOP;
 IF v_total<=0 THEN
  UPDATE private.return_requests SET status='rejected',inspected_by=auth.uid(),inspected_at=now(),
   inspection_notes=coalesce(nullif(btrim(coalesce(p_notes,'')),''),'لم يتم قبول أي منتج بعد الفحص'),refund_amount=0,updated_at=now()
  WHERE id=p_request_id;
  INSERT INTO private.return_request_events(return_request_id,from_status,to_status,actor_user_id,note)
  VALUES(p_request_id,'received','rejected',auth.uid(),'لم يتم قبول أي منتج بعد الفحص');
  RETURN json_build_object('success',true,'status','rejected','refund_amount',0);
 END IF;
 UPDATE private.return_requests SET
  status=CASE WHEN request_type='return' THEN 'inspected' ELSE 'exchange_pending' END,
  inspected_by=auth.uid(),inspected_at=now(),
  inspection_notes=nullif(btrim(coalesce(p_notes,'')),''),
  refund_amount=CASE WHEN request_type='return' THEN v_total ELSE 0 END,updated_at=now()
 WHERE id=p_request_id;
 INSERT INTO private.return_request_events(return_request_id,from_status,to_status,actor_user_id,note)
 VALUES(p_request_id,'received',CASE WHEN v_req.request_type='return' THEN 'inspected' ELSE 'exchange_pending' END,auth.uid(),nullif(btrim(coalesce(p_notes,'')),''));
 RETURN json_build_object('success',true,'status',CASE WHEN v_req.request_type='return' THEN 'inspected' ELSE 'exchange_pending' END,'refund_amount',v_total);
END; $function$;
REVOKE ALL ON FUNCTION public.admin_inspect_return_request(bigint,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_inspect_return_request(bigint,jsonb,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_complete_return_exchange(p_request_id bigint,p_replacement_order_id bigint,p_notes text DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE v_role text:=public.current_staff_role(); v_req private.return_requests%rowtype; v_new public.orders%rowtype;
BEGIN
 IF auth.uid() IS NULL OR coalesce(v_role,'') NOT IN ('owner','manager') THEN RAISE EXCEPTION 'Owner or manager access required'; END IF;
 SELECT * INTO v_req FROM private.return_requests WHERE id=p_request_id FOR UPDATE;
 IF NOT FOUND OR v_req.request_type<>'exchange' OR v_req.status<>'exchange_pending' THEN RAISE EXCEPTION 'طلب الاستبدال غير جاهز للإتمام'; END IF;
 SELECT * INTO v_new FROM public.orders WHERE id=p_replacement_order_id FOR SHARE;
 IF NOT FOUND OR v_new.id=v_req.order_id OR v_new.created_at<v_req.created_at
   OR v_new.customer_user_id IS DISTINCT FROM v_req.customer_user_id OR v_new.status='cancelled' THEN
  RAISE EXCEPTION 'طلب البديل غير صحيح أو لا يخص نفس العميل أو لم يتم إنشاؤه بعد طلب الاستبدال';
 END IF;
 UPDATE private.return_requests SET status='exchanged',replacement_order_id=p_replacement_order_id,updated_at=now() WHERE id=p_request_id;
 INSERT INTO private.return_request_events(return_request_id,from_status,to_status,actor_user_id,note)
 VALUES(p_request_id,'exchange_pending','exchanged',auth.uid(),concat('طلب البديل #',p_replacement_order_id,' ',coalesce(p_notes,'')));
 RETURN json_build_object('success',true,'status','exchanged','replacement_order_id',p_replacement_order_id);
END; $function$;
REVOKE ALL ON FUNCTION public.admin_complete_return_exchange(bigint,bigint,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_complete_return_exchange(bigint,bigint,text) TO authenticated;