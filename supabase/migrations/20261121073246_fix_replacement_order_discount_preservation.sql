do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.admin_complete_return_exchange(bigint,bigint,text)'::regprocedure);
 v_def:=replace(v_def,
   '   discount_amount=0,'||chr(10)||'   coupon_code=null,'||chr(10),
   '');
 execute v_def;
end $$;
