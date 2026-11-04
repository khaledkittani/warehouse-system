/* إدارة كوابل DC - ربط الأكواد يدوياً */
function dcEnsureState(){
  if(!STATE.dcCables) STATE.dcCables = {receipts:[], consumption:[], alerts:[], mappings:{'6':[],'10':[],'16':[]}};
  if(!Array.isArray(STATE.dcCables.receipts)) STATE.dcCables.receipts = [];
  if(!Array.isArray(STATE.dcCables.consumption)) STATE.dcCables.consumption = [];
  if(!Array.isArray(STATE.dcCables.alerts)) STATE.dcCables.alerts = [];
  if(!STATE.dcCables.mappings) STATE.dcCables.mappings = {'6':[],'10':[],'16':[]};
  if(!Array.isArray(STATE.dcCables.mappings['6'])) STATE.dcCables.mappings['6'] = [];
  if(!Array.isArray(STATE.dcCables.mappings['10'])) STATE.dcCables.mappings['10'] = [];
  if(!Array.isArray(STATE.dcCables.mappings['16'])) STATE.dcCables.mappings['16'] = [];
}

function dcGetCodeToSize(){
  dcEnsureState();
  const map = {};
  ['6','10','16'].forEach(sz=>{
    (STATE.dcCables.mappings[sz]||[]).forEach(code=>{
      const c = String(code||'').trim().toLowerCase();
      if(c) map[c] = sz;
    });
  });
  return map;
}

function dcDetectReplacementNote(note){
  if(!note) return {replaced:false, usedSize:null, origSize:null, clear:false, reviewNeeded:false, reason:''};
  const s = String(note);
  const m = s.match(/(?:DC\s*)?(1[06]|6)\s*(?:mm[²2]?)\s*(?:بدل|عوض\s*عن|بدلا\s*من|instead\s*of|replaced\s*.*\s*with|with\s*.*\s*instead)\s*(?:DC\s*)?(1[06]|6)/i);
  if(m){
    const used = m[1], orig = m[2];
    if(used && orig && used !== orig){
      return {replaced:true, usedSize: used, origSize: orig, clear:true, reviewNeeded:false, reason:`استبدال DC ${orig} mm² بـ DC ${used} mm²`};
    }
  }
  if(/بدل|استبدال|replac/i.test(s) && /(1[06]|6)/.test(s)){
    return {replaced:false, usedSize:null, origSize:null, clear:false, reviewNeeded:true, reason:'ملاحظة استبدال غير واضحة أو نوع بديل غير محدد'};
  }
  return {replaced:false, usedSize:null, origSize:null, clear:false, reviewNeeded:false, reason:''};
}

function dcExtractFromSidImport(importEntry){
  dcEnsureState();
  const codeToSize = dcGetCodeToSize();
  const site = trim(importEntry.site||'');
  const fileName = importEntry.fileName||'';
  const sheetName = importEntry.sheetName||'';
  const importedAt = importEntry.importedAt||new Date().toISOString();
  const signature = importEntry.signature||'';
  const rows = Array.isArray(importEntry.rows)?importEntry.rows:[];
  const items = [];
  const alerts = [];
  rows.forEach(r=>{
    const code = String(r.productCode||r.code||'').trim().toLowerCase();
    if(!code) return;
    const mappedSize = codeToSize[code];
    if(!mappedSize) return; // only count mapped codes
    const req = Number(r.requested||0);
    if(req <= 0) return;
    const desc = r.productDescription || r.description || r.productCode || '';
    const note = r.notes || r.note || '';
    const rep = dcDetectReplacementNote(note);
    if(rep.replaced && rep.usedSize && rep.clear && (rep.usedSize==='6'||rep.usedSize==='10'||rep.usedSize==='16')){
      items.push({
        productCode: r.productCode||'',
        productDescription: desc,
        origSize: mappedSize,
        usedSize: rep.usedSize,
        qty: req,
        requestedQty: req,
        replaced: true,
        replacementNote: rep.reason || note,
        reviewNeeded: false
      });
      return;
    }
    if(rep.reviewNeeded){
      alerts.push({id:nextId(), site, fileName, reason:'ملاحظة استبدال غير واضحة', detail:`كود ${r.productCode||''} ${desc} - ${req} م - ${note}`, createdAt:new Date().toISOString(), resolved:false});
      items.push({
        productCode: r.productCode||'',
        productDescription: desc,
        origSize: mappedSize,
        usedSize: mappedSize,
        qty: req,
        requestedQty: req,
        replaced: false,
        replacementNote: note,
        reviewNeeded: true
      });
      return;
    }
    items.push({
      productCode: r.productCode||'',
      productDescription: desc,
      origSize: mappedSize,
      usedSize: mappedSize,
      qty: req,
      requestedQty: req,
      replaced: false,
      replacementNote: note||'',
      reviewNeeded: false
    });
  });
  const totals = {qty6:0, qty10:0, qty16:0};
  items.forEach(it=>{
    if(it.reviewNeeded) return;
    if(it.usedSize==='6') totals.qty6 += Number(it.qty||0);
    if(it.usedSize==='10') totals.qty10 += Number(it.qty||0);
    if(it.usedSize==='16') totals.qty16 += Number(it.qty||0);
  });
  return {site, fileName, sheetName, importedAt, signature, items, totals, alerts};
}

function dcRebuildConsumptionFromSid(){
  dcEnsureState();
  const prevAlerts = (STATE.dcCables.alerts||[]).filter(a=>a.resolved);
  const newList = [];
  const allAlerts = [...prevAlerts];
  (STATE.sidReview.imports||[]).forEach(imp=>{
    const res = dcExtractFromSidImport(imp);
    if(res.items.length > 0 || true){ // store even if empty? better store per site
      // check if same site already exists, replace
    }
    newList.push({
      id: 'DCC'+Date.now().toString(36)+Math.random().toString(36).slice(2,6),
      site: res.site,
      fileName: res.fileName,
      sheetName: res.sheetName,
      importedAt: res.importedAt,
      signature: res.signature,
      items: res.items,
      totals: res.totals
    });
    (res.alerts||[]).forEach(al=>{
      allAlerts.push(al);
    });
  });
  // group by site - replace per site
  const bySite = {};
  newList.forEach(x=>{
    bySite[x.site.toLowerCase()] = x;
  });
  const out = Object.values(bySite);
  STATE.dcCables.consumption = out;
  const seen = new Set();
  const merged = [];
  allAlerts.slice().reverse().forEach(a=>{
    const key = (a.site||'')+'|'+(a.detail||'')+'|'+(a.reason||'');
    if(seen.has(key)) return;
    seen.add(key);
    merged.push(a);
  });
  STATE.dcCables.alerts = merged.slice(0,300);
}
