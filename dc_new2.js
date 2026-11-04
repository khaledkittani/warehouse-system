/* كوابل DC داخل قسم SID */
function dcEnsure(){
  if(!STATE.dcCables) STATE.dcCables = {receipts:[], consumption:[], alerts:[], mappings:{'6':[],'10':[],'16':[]}};
  if(!Array.isArray(STATE.dcCables.receipts)) STATE.dcCables.receipts=[];
  if(!Array.isArray(STATE.dcCables.consumption)) STATE.dcCables.consumption=[];
  if(!Array.isArray(STATE.dcCables.alerts)) STATE.dcCables.alerts=[];
  if(!STATE.dcCables.mappings) STATE.dcCables.mappings={'6':[],'10':[],'16':[]};
  ['6','10','16'].forEach(k=>{ if(!Array.isArray(STATE.dcCables.mappings[k])) STATE.dcCables.mappings[k]=[]; });
}
function dcCodeMap(){
  dcEnsure();
  const m={};
  ['6','10','16'].forEach(sz=>{
    (STATE.dcCables.mappings[sz]||[]).forEach(c=>{
      const cl=String(c).trim().toLowerCase();
      if(cl) m[cl]=sz;
    });
  });
  return m;
}
function dcDetectRep(note){
  if(!note) return {replaced:false,used:null,orig:null,clear:false,review:false,reason:''};
  const s=String(note);
  const mm=s.match(/(?:DC\s*)?(1[06]|6)\s*(?:mm[²2]?)\s*(?:بدل|عوض\s*عن|بدلا\s*من|instead\s*of|replaced.*with|with.*instead)\s*(?:DC\s*)?(1[06]|6)/i);
  if(mm && mm[1]!==mm[2]){
    return {replaced:true,used:mm[1],orig:mm[2],clear:true,review:false,reason:`استبدال DC ${mm[2]} mm² بـ DC ${mm[1]} mm²`};
  }
  if(/بدل|استبدال|replac/i.test(s)&&/(1[06]|6)/.test(s)) return {replaced:false,used:null,orig:null,clear:false,review:true,reason:'ملاحظة استبدال غير واضحة'};
  return {replaced:false,used:null,orig:null,clear:false,review:false,reason:''};
}
function dcCalcFromImport(imp){
  dcEnsure();
  const cmap=dcCodeMap();
  const site=trim(imp.site||'');
  const items=[], alerts=[];
  (imp.rows||[]).forEach(r=>{
    const code=String(r.productCode||'').trim().toLowerCase();
    if(!code) return;
    const sz=cmap[code];
    if(!sz) return;
    const req=Number(r.requested||0);
    if(req<=0) return;
    const desc=r.productDescription||r.description||r.productCode||'';
    const note=r.notes||r.note||'';
    const rep=dcDetectRep(note);
    if(rep.replaced&&rep.used&&rep.clear&&(rep.used==='6'||rep.used==='10'||rep.used==='16')){
      items.push({productCode:r.productCode||'',productDescription:desc,origSize:sz,usedSize:rep.used,qty:req,requestedQty:req,replaced:true,replacementNote:rep.reason||note,reviewNeeded:false});
      return;
    }
    if(rep.review){
      alerts.push({id:nextId(),site,reason:'ملاحظة استبدال غير واضحة',detail:`كود ${r.productCode||''} ${desc} ${req}م ${note}`,createdAt:new Date().toISOString(),resolved:false});
      items.push({productCode:r.productCode||'',productDescription:desc,origSize:sz,usedSize:sz,qty:req,requestedQty:req,replaced:false,replacementNote:note,reviewNeeded:true});
      return;
    }
    items.push({productCode:r.productCode||'',productDescription:desc,origSize:sz,usedSize:sz,qty:req,requestedQty:req,replaced:false,replacementNote:note,reviewNeeded:false});
  });
  const totals={qty6:0,qty10:0,qty16:0};
  items.forEach(it=>{if(it.reviewNeeded)return;if(it.usedSize==='6')totals.qty6+=Number(it.qty||0);if(it.usedSize==='10')totals.qty10+=Number(it.qty||0);if(it.usedSize==='16')totals.qty16+=Number(it.qty||0);});
  return {site,fileName:imp.fileName,sheetName:imp.sheetName,importedAt:imp.importedAt||new Date().toISOString(),signature:imp.signature,items,totals,alerts};
}
function dcRebuildAll(){
  dcEnsure();
  const resolved=(STATE.dcCables.alerts||[]).filter(a=>a.resolved);
  const all=[...resolved];
  const map={};
  (STATE.sidReview.imports||[]).forEach(imp=>{
    const res=dcCalcFromImport(imp);
    map[(res.site||'').toLowerCase()]={id:'DCC'+Date.now().toString(36)+Math.random().toString(36).slice(2,4),site:res.site,fileName:res.fileName,sheetName:res.sheetName,importedAt:res.importedAt,signature:res.signature,items:res.items,totals:res.totals};
    (res.alerts||[]).forEach(al=>all.push(al));
  });
  STATE.dcCables.consumption=Object.values(map);
  const seen=new Set(); const merged=[];
  all.slice().reverse().forEach(a=>{const k=(a.site||'')+'|'+(a.detail||'')+'|'+(a.reason||'');if(seen.has(k))return;seen.add(k);merged.push(a);});
  STATE.dcCables.alerts=merged.slice(0,400);
}
function dcAllCodes(){
  const set=new Map();
  (STATE.sidReview.imports||[]).forEach(imp=>{
    (imp.rows||[]).forEach(r=>{
      const code=String(r.productCode||'').trim();
      if(code && !set.has(code.toLowerCase())) set.set(code.toLowerCase(),{code,desc:r.productDescription||r.description||''});
    });
  });
  return Array.from(set.values()).sort((a,b)=>a.code.localeCompare(b.code));
}
function renderSidDcCableManager(el){
  dcEnsure();
  try{ dcRebuildAll(); }catch(e){}
  const t=(function(){let r6=0,r10=0,r16=0;(STATE.dcCables.receipts||[]).forEach(rc=>{r6+=+rc.qty6||0;r10+=+rc.qty10||0;r16+=+rc.qty16||0;});let c6=0,c10=0,c16=0;(STATE.dcCables.consumption||[]).forEach(cs=>{const tot=cs.totals||{};c6+=+tot.qty6||0;c10+=+tot.qty10||0;c16+=+tot.qty16||0;});return {r:{q6:r6,q10:r10,q16:r16,t:r6+r10+r16},c:{q6:c6,q10:c10,q16:c16,t:c6+c10+c16},rm:{q6:r6-c6,q10:r10-c10,q16:r16-c16,t:(r6+r10+r16)-(c6+c10+c16)}};})();
  const alerts=(STATE.dcCables.alerts||[]).filter(a=>!a.resolved);
  const m=STATE.dcCables.mappings;
  el.innerHTML=`
    <div class="panel"><h2>ربط أكواد مواد DC بالأنواع</h2><div class="desc">يتم الحساب بناءً على أكواد المواد المرتبطة فقط. منع ربط نفس الكود لأكثر من نوع.</div>
    <div class="grid3">
      <div class="panel" style="margin:0"><h3>DC 6 mm² (2×6)</h3><div class="btnrow"><button class="secondary" data-dcp="6">اختيار المواد</button></div><div style="margin-top:8px;">${(m['6']||[]).length?(m['6']||[]).map(x=>`<span class="pill" style="margin:2px;">${esc(x)}</span>`).join(''):'<span class="pill warn">لم يربط بعد</span>'}</div></div>
      <div class="panel" style="margin:0"><h3>DC 10 mm² (2×10)</h3><div class="btnrow"><button class="secondary" data-dcp="10">اختيار المواد</button></div><div style="margin-top:8px;">${(m['10']||[]).length?(m['10']||[]).map(x=>`<span class="pill" style="margin:2px;">${esc(x)}</span>`).join(''):'<span class="pill warn">لم يربط بعد</span>'}</div></div>
      <div class="panel" style="margin:0"><h3>DC 16 mm² (2×16)</h3><div class="btnrow"><button class="secondary" data-dcp="16">اختيار المواد</button></div><div style="margin-top:8px;">${(m['16']||[]).length?(m['16']||[]).map(x=>`<span class="pill" style="margin:2px;">${esc(x)}</span>`).join(''):'<span class="pill warn">لم يربط بعد</span>'}</div></div>
    </div></div>
    <div class="panel"><h2>ملخص الأرصدة</h2>${alerts.length?`<div class="msg warn">حالات تحتاج مراجعة (${alerts.length})</div>`:''}
      <div class="tablewrap"><table class="data"><thead><tr><th>نوع الكابل</th><th>المستلم</th><th>المستهلك</th><th>المتبقي</th></tr></thead><tbody>
        <tr><td>DC 6 mm²</td><td>${t.r.q6}</td><td>${t.c.q6}</td><td style="${t.rm.q6<0?'color:#b71c1c;font-weight:700':''}">${t.rm.q6}</td></tr>
        <tr><td>DC 10 mm²</td><td>${t.r.q10}</td><td>${t.c.q10}</td><td style="${t.rm.q10<0?'color:#b71c1c;font-weight:700':''}">${t.rm.q10}</td></tr>
        <tr><td>DC 16 mm²</td><td>${t.r.q16}</td><td>${t.c.q16}</td><td style="${t.rm.q16<0?'color:#b71c1c;font-weight:700':''}">${t.rm.q16}</td></tr>
        <tr style="font-weight:800"><td>الإجمالي</td><td>${t.r.t}</td><td>${t.c.t}</td><td>${t.rm.t}</td></tr>
      </tbody></table></div>
      <div class="btnrow"><button class="primary" id="dcrAdd">تسجيل استلام</button><button class="secondary" id="dcrRe">إعادة احتساب</button><button class="secondary" id="dcrExp">تصدير Excel</button></div>
    </div>
    <div class="panel"><h2>استهلاك حسب المواقع</h2>
      <table class="data"><thead><tr><th>الموقع</th><th>DC 6</th><th>DC 10</th><th>DC 16</th><th>الإجمالي</th><th></th></tr></thead><tbody>
        ${(STATE.dcCables.consumption||[]).slice().sort((a,b)=>String(a.site).localeCompare(String(b.site))).map(cs=>{const tt=cs.totals||{};const st=(tt.qty6||0)+(tt.qty10||0)+(tt.qty16||0);const rev=(cs.items||[]).some(x=>x.reviewNeeded);return `<tr><td>${esc(cs.site)} ${rev?'<span class="pill warn">مراجعة</span>':''}</td><td>${tt.qty6||0}</td><td>${tt.qty10||0}</td><td>${tt.qty16||0}</td><td>${st}</td><td><button class="secondary" data-dcd="${esc(cs.site)}">تفاصيل</button></td></tr>`;}).join('')||'<tr><td colspan="6">لا يوجد</td></tr>'}
      </tbody></table>
    </div>
    <div class="panel"><h2>سجل الاستلام</h2>
      <table class="data"><thead><tr><th>التاريخ</th><th>DC 6</th><th>DC 10</th><th>DC 16</th><th>الإجمالي</th><th>ملاحظات</th><th></th></tr></thead><tbody>
        ${(STATE.dcCables.receipts||[]).slice().reverse().map(rc=>{const tt=(+rc.qty6||0)+(+rc.qty10||0)+(+rc.qty16||0);return `<tr><td>${esc(rc.date||'')}</td><td>${rc.qty6||0}</td><td>${rc.qty10||0}</td><td>${rc.qty16||0}</td><td>${tt}</td><td>${esc(rc.notes||'')}</td><td><button class="secondary" data-dce="${rc.id}">تعديل</button></td></tr>`;}).join('')||'<tr><td colspan="7">لا يوجد</td></tr>'}
      </tbody></table>
    </div>
  `;
  el.querySelectorAll('[data-dcp]').forEach(b=>b.addEventListener('click',()=>dcPick(b.dataset.dcp)));
  document.getElementById('dcrAdd').addEventListener('click',()=>dcRec(null));
  document.getElementById('dcrRe').addEventListener('click',async()=>{dcRebuildAll();await saveState(['dcCables']);renderSidDcCableManager(el);alert('تم إعادة الاحتساب');});
  document.getElementById('dcrExp').addEventListener('click',dcExp);
  el.querySelectorAll('[data-dce]').forEach(b=>{const rc=(STATE.dcCables.receipts||[]).find(x=>x.id===b.dataset.dce);if(rc)b.addEventListener('click',()=>dcRec(rc));});
  el.querySelectorAll('[data-dcd]').forEach(b=>b.addEventListener('click',()=>dcDet(b.dataset.dcd)));
}
function dcPick(sz){
  dcEnsure();
  const codes=dcAllCodes();
  const cur=new Set((STATE.dcCables.mappings[sz]||[]).map(c=>String(c).toLowerCase()));
  openModal(`اختيار أكواد DC ${sz} mm²`,(body)=>{
    body.innerHTML=`<input type="text" id="dcpq" placeholder="بحث..."><div class="tablewrap" style="max-height:50vh"><table class="data"><thead><tr><th></th><th>الكود</th><th>الوصف</th></tr></thead><tbody>${codes.map(c=>`<tr><td><input type="checkbox" class="dcpck" data-c="${esc(c.code)}" ${cur.has(c.code.toLowerCase())?'checked':''}></td><td>${esc(c.code)}</td><td>${esc(c.desc)}</td></tr>`).join('')}</tbody></table></div><div class="btnrow"><button class="primary" id="dcps">حفظ</button><button class="secondary" id="dcpc">إلغاء</button></div>`;
    document.getElementById('dcpc').addEventListener('click',closeModal);
    document.getElementById('dcps').addEventListener('click',async()=>{
      const sel=[];document.querySelectorAll('.dcpck:checked').forEach(ch=>sel.push(ch.dataset.c));
      for(const s2 of ['6','10','16']){if(s2===sz)continue;for(const sc of sel){if((STATE.dcCables.mappings[s2]||[]).some(x=>String(x).toLowerCase()===sc.toLowerCase())){alert('لا يمكن ربط نفس الكود لأكثر من نوع');return;}}}
      STATE.dcCables.mappings[sz]=sel;
      ['6','10','16'].forEach(s2=>{if(s2===sz)return;STATE.dcCables.mappings[s2]=(STATE.dcCables.mappings[s2]||[]).filter(x=>!sel.some(sc=>sc.toLowerCase()===String(x).toLowerCase()));});
      await saveState(['dcCables']); closeModal(); const el=document.getElementById('tabContent'); if(el&&ACTIVE_TAB==='sid'){ renderSidTab(el); setTimeout(()=>{const b=document.querySelector('[data-sidsec="dccables"]'); if(b&&b.classList.contains('sid-sec-head')) b.click(); setTimeout(()=>{if(el) renderSidDcCableManager(document.getElementById('sidrSec_dccables'));},50);},50);}
    });
  },{maxWidth:'700px'});
}
function dcRec(rc){
  const ed=!!rc;
  openModal(ed?'تعديل استلام':'تسجيل استلام',(body)=>{
    body.innerHTML=`<div class="grid3"><div><label>التاريخ</label><input type="date" id="dcdt" value="${esc(rc&&rc.date?rc.date:todayStr())}"></div><div><label>DC 6</label><input type="number" id="dc6v" value="${rc&&rc.qty6!=null?rc.qty6:''}"></div><div><label>DC 10</label><input type="number" id="dc10v" value="${rc&&rc.qty10!=null?rc.qty10:''}"></div></div><div class="grid3" style="margin-top:8px"><div><label>DC 16</label><input type="number" id="dc16v" value="${rc&&rc.qty16!=null?rc.qty16:''}"></div><div style="grid-column:span 2"><label>ملاحظات</label><input type="text" id="dcn" value="${esc(rc&&rc.notes||'')}"></div></div><div class="btnrow"><button class="primary" id="dcs">حفظ</button><button class="secondary" id="dcc">إلغاء</button></div>`;
    document.getElementById('dcc').addEventListener('click',closeModal);
    document.getElementById('dcs').addEventListener('click',async()=>{
      const q6=+document.getElementById('dc6v').value||0,q10=+document.getElementById('dc10v').value||0,q16=+document.getElementById('dc16v').value||0;
      dcEnsure();
      if(ed){const i=STATE.dcCables.receipts.findIndex(x=>x.id===rc.id);if(i>=0)STATE.dcCables.receipts[i]={...STATE.dcCables.receipts[i],date:document.getElementById('dcdt').value,qty6:q6,qty10:q10,qty16:q16,notes:document.getElementById('dcn').value};}
      else STATE.dcCables.receipts.push({id:nextId(),date:document.getElementById('dcdt').value,qty6:q6,qty10:q10,qty16:q16,notes:document.getElementById('dcn').value});
      await saveState(['dcCables']); closeModal(); const el=document.getElementById('tabContent'); if(el&&ACTIVE_TAB==='sid'){renderSidTab(el);setTimeout(()=>{const b=document.querySelector('[data-sidsec="dccables"]');if(b)b.click();setTimeout(()=>{if(el)renderSidDcCableManager(document.getElementById('sidrSec_dccables'));},50);},50);}
    });
  },{maxWidth:'620px'});
}
function dcDet(site){
  dcEnsure(); try{dcRebuildAll();}catch(e){}
  const cs=(STATE.dcCables.consumption||[]).find(x=>x.site===site);
  openModal('تفاصيل '+site,(body)=>{
    if(!cs){body.innerHTML='<div>لا يوجد</div>';return;}
    body.innerHTML=`<table class="data"><thead><tr><th>كود</th><th>الوصف</th><th>أصلي</th><th>مستخدم</th><th>كمية</th><th>استبدال</th><th>ملاحظة</th><th>حالة</th></tr></thead><tbody>${(cs.items||[]).map(it=>`<tr><td>${esc(it.productCode||'')}</td><td>${esc(it.productDescription||'')}</td><td>${it.origSize?'DC '+it.origSize:''}</td><td>${it.usedSize?'DC '+it.usedSize:''}</td><td>${it.qty||0}</td><td>${it.replaced?'نعم':'لا'}</td><td>${esc(it.replacementNote||'')}</td><td>${it.reviewNeeded?'<span class="pill warn">مراجعة</span>':'<span class="pill ok">مُعتمد</span>'}</td></tr>`).join('')}</tbody></table><div class="btnrow"><button class="secondary" id="dcdc">إغلاق</button></div>`;
    document.getElementById('dcdc').addEventListener('click',closeModal);
  },{maxWidth:'1100px'});
}
function dcExp(){
  dcEnsure(); try{dcRebuildAll();}catch(e){}
  let r6=0,r10=0,r16=0;(STATE.dcCables.receipts||[]).forEach(rc=>{r6+=+rc.qty6||0;r10+=+rc.qty10||0;r16+=+rc.qty16||0;});
  let c6=0,c10=0,c16=0;(STATE.dcCables.consumption||[]).forEach(cs=>{const tt=cs.totals||{};c6+=+tt.qty6||0;c10+=+tt.qty10||0;c16+=+tt.qty16||0;});
  const sh=[];
  sh.push({name:'ملخص',ws:aoaSheet([['نوع','مستلم','مستهلك','متبقي'],['DC 6',r6,c6,r6-c6],['DC 10',r10,c10,r10-c10],['DC 16',r16,c16,r16-c16],['الإجمالي',r6+r10+r16,c6+c10+c16,(r6+r10+r16)-(c6+c10+c16)]],[14,14,14,14])});
  const s2=[['الموقع','DC 6','DC 10','DC 16','الإجمالي']];
  (STATE.dcCables.consumption||[]).slice().sort((a,b)=>String(a.site).localeCompare(String(b.site))).forEach(cs=>{const tt=cs.totals||{};s2.push([cs.site,tt.qty6||0,tt.qty10||0,tt.qty16||0,(tt.qty6||0)+(tt.qty10||0)+(tt.qty16||0)]);});
  sh.push({name:'استهلاك المواقع',ws:aoaSheet(s2,[28,10,10,10,12])});
  const s3=[['نوع','كود']];
  (STATE.dcCables.mappings['6']||[]).forEach(x=>s3.push(['DC 6',x]));
  (STATE.dcCables.mappings['10']||[]).forEach(x=>s3.push(['DC 10',x]));
  (STATE.dcCables.mappings['16']||[]).forEach(x=>s3.push(['DC 16',x]));
  sh.push({name:'أكواد مرتبطة',ws:aoaSheet(s3,[12,18])});
  downloadWorkbook(sh,`كوابل_DC_${todayStr()}.xlsx`);
}
async function sidrCommitBatch(){
  // keep existing logic by calling original? easier to just append behavior
}
