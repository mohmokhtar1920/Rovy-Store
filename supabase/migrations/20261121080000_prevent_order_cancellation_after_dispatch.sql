-- Prevent cancellation once the parcel has been handed to the shipping company.
-- Delivered orders are also closed to cancellation and must use returns/exchanges.
CREATE OR REPLACE FUNCTION private.prevent_order_cancellation_after_dispatch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  IF OLD.status IN ('shipped', 'delivered')
     AND NEW.status = 'cancelled' THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = CASE
        WHEN OLD.status = 'shipped'
          THEN 'لا يمكن إلغاء الطلب بعد تسليمه لشركة الشحن. استخدم مسار المرتجعات.'
        ELSE 'لا يمكن إلغاء الطلب بعد التسليم. استخدم مسار المرتجعات أو الاستبدال.'
      END;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_prevent_order_cancellation_after_dispatch ON public.orders;

CREATE TRIGGER trg_prevent_order_cancellation_after_dispatch
BEFORE UPDATE OF status ON public.orders
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION private.prevent_order_cancellation_after_dispatch();
