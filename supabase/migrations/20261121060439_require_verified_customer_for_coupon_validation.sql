-- Restrict coupon validation to signed-in customers with confirmed email.
-- Checkout already enforces this requirement in the UI; this adds the same
-- protection at the RPC boundary so anonymous callers cannot enumerate codes.

CREATE OR REPLACE FUNCTION public.validate_coupon(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_code text := nullif(pg_catalog.upper(pg_catalog.btrim(p_code)), '');
  v_pct integer;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM auth.users u
    WHERE u.id = auth.uid()
      AND u.email_confirmed_at IS NOT NULL
  ) THEN
    RETURN pg_catalog.jsonb_build_object('valid', false);
  END IF;

  IF v_code IS NULL OR pg_catalog.length(v_code) > 64 THEN
    RETURN pg_catalog.jsonb_build_object('valid', false);
  END IF;

  SELECT c.discount_percentage
  INTO v_pct
  FROM public.coupons c
  WHERE pg_catalog.upper(c.code) = v_code
    AND c.is_active IS TRUE
  LIMIT 1;

  IF v_pct IS NULL OR v_pct < 1 OR v_pct > 100 THEN
    RETURN pg_catalog.jsonb_build_object('valid', false);
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'valid', true,
    'discount_percentage', v_pct
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.validate_coupon(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.validate_coupon(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.validate_coupon(text) TO authenticated, service_role;
