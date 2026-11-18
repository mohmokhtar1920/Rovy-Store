(function(){
  'use strict';
  const URL='https://bkjwfmjxmxgxgaxwrnsh.supabase.co';
  const KEY='sb_publishable_3nR3DUDrxahFNVH1j62Uow_YPexuzwb';
  const STORE_KEY='sb-bkjwfmjxmxgxgaxwrnsh-auth-token';
  const VISITOR_KEY='rovyAnalyticsVisitor';
  const SESSION_KEY='rovyAnalyticsSession';
  function uuid(){try{return crypto.randomUUID();}catch(e){return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{const r=Math.random()*16|0;return(c==='x'?r:(r&3|8)).toString(16);});}}
  function getId(storage,key){let v=storage.getItem(key);if(!v||!/^[0-9a-f-]{36}$/i.test(v)){v=uuid();storage.setItem(key,v);}return v;}
  let visitorId,sessionId,client;
  try{
    visitorId=getId(localStorage,VISITOR_KEY);
    sessionId=getId(sessionStorage,SESSION_KEY);
    if(window.supabase?.createClient)client=window.supabase.createClient(URL,KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true,storageKey:STORE_KEY}});
  }catch(e){return;}
  function sourceName(){
    const saved=sessionStorage.getItem('rovyAnalyticsSessionSource');
    if(saved)return saved;
    const q=new URLSearchParams(location.search);
    const utm=(q.get('utm_source')||q.get('source')||'').toLowerCase();
    let value='';
    if(utm)value=utm.slice(0,80);
    else{
      let h='';try{h=document.referrer?new URL(document.referrer).hostname.replace(/^www\./,'').toLowerCase():'';}catch(e){}
      if(!h)value='direct';
      else if(/facebook|fb\./.test(h))value='facebook';
      else if(/instagram/.test(h))value='instagram';
      else if(/google/.test(h))value='google';
      else if(/tiktok/.test(h))value='tiktok';
      else if(/youtube/.test(h))value='youtube';
      else value=h.slice(0,80);
    }
    sessionStorage.setItem('rovyAnalyticsSessionSource',value);
    return value;
  }
  async function track(type,opts){
    if(!client)return false;
    opts=opts||{};
    try{
      const {data:{user}}=await client.auth.getUser().catch(()=>({data:{user:null}}));
      const {error}=await client.rpc('track_store_event',{
        p_visitor_id:visitorId,p_session_id:sessionId,p_event_type:type,
        p_product_id:Number.isSafeInteger(Number(opts.product_id))&&Number(opts.product_id)>0?Number(opts.product_id):null,
        p_page_path:location.pathname,
        p_source:sourceName(),
        p_referrer_host:(()=>{try{return document.referrer?new URL(document.referrer).hostname:'';}catch(e){return '';}})(),
        p_metadata:opts.metadata||{}
      });
      if(error)throw error;
      return true;
    }catch(e){console.debug('ROVY analytics event skipped:',e.message||e);return false;}
  }
  window.rovyAnalytics={track,visitorId};
  const page=location.pathname.split('/').pop()||'index.html';
  track('page_view');
  if(page==='product.html'){
    const id=Number(new URLSearchParams(location.search).get('id'));
    if(Number.isSafeInteger(id)&&id>0)track('product_view',{product_id:id});
  }
  if(page==='checkout.html'){
    try{const cart=JSON.parse(localStorage.getItem('rovyCart')||'[]');if(Array.isArray(cart)&&cart.length)track('begin_checkout');}catch(e){}
  }
  if(client){
    client.auth.onAuthStateChange((event,session)=>{
      if(event==='SIGNED_IN'&&session?.user){
        const u=session.user, key='rovyAnalyticsSignupTracked';
        const created=Date.parse(u.created_at||'');
        if(created&&Date.now()-created<10*60*1000&&localStorage.getItem(key)!==u.id){
          localStorage.setItem(key,u.id);setTimeout(()=>track('signup_completed'),0);
        }else setTimeout(()=>track('login'),0);
      }
    });
  }
})();