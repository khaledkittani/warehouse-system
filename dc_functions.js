/* ===================== إدارة كوابل DC ===================== */
function dcEnsureState(){
  if(!STATE.dcCables) STATE.dcCables = {receipts:[], consumption:[], alerts:[]};
  if(!Array.isArray(STATE.dcCables.receipts)) STATE.dcCables.receipts = [];
  if(!Array.isArray(STATE.dcCables.consumption)) STATE.dcCables.consumption = [];
  if(!Array.isArray(STATE.dcCables.alerts)) STATE.dcCables.alerts = [];
}

function dcCableTypeFromText(text){
  const t = String(text||'').toLowerCase().replace(/\s+/g,'');
  if(t.includes('2x16') || t.includes('2*16') || t.includes('2×16')) return '2x16';
  if(t.includes('2x10') || t.includes('2*10') || t.includes('2×10')) return '2x10';
  if(t.includes('2x6')  || t.includes('2*6')  || t.includes('2×6'))  return '2x6';
  if(t.includes('16mm')) return '2x16';
  if(t.includes('10mm')) return '2x10';
  if(t.includes('6mm'))  return '2x6';
  return null;
}

function dcDetectReplacement(note){
  if(!note) return {replaced:false, usedType:null, origType:null, clear:false, reviewNeeded:false, reason:''};
  const s = String(note).toLowerCase();
  // look for patterns like 10 بدل 6, استخدمنا 10 بدل 6, 2x10 instead of 2x6, replaced 6mm with 10mm
  let m = s.match(/(2\s*[x×*]\s*)?(16|10|6)\s*(mm)?\s*(بدل|عوضا عن|بدلا من|instead of|replaced.*with|with.*instead|replace.*by)/i);
  if(!m){
    // other way
    m = s.match(/(بدل|عوضا عن|بدلا من|instead of|replaced.*from).*?(2\s*[x×*]\s*)?(16|10|6)/i);
  }
  // also try "10 بدل 6"
  const m2 = s.match(/(?:2\s*[x×*]\s*)?(1[06]|6)\s*(?:mm\s*)?(?:بدل|عوض\s*عن|بدلاً\s*من|بدلا\s*من)\s*(?:2\s*[x×*]\s*)?(1[06]|6)/i);
  if(m2){
    const used = '2x'+m2[1];
    const orig = '2x'+m2[2];
    if((used==='2x10'||used==='2x16') && (orig==='2x6')){
      return {replaced:true, usedType:used, origType:orig, clear:true, reviewNeeded:false, reason:`استبدال ${orig} بـ ${used}`};
    }
    if(used==='2x16' && orig==='2x10'){
      return {replaced:true, usedType:used, origType:orig, clear:true, reviewNeeded:false, reason:`استبدال ${orig} بـ ${used}`};
    }
    // if using larger/smaller not matching expected cases, still try to be explicit
    return {replaced:true, usedType:used, origType:orig, clear:true, reviewNeeded:false, reason:`استبدال ${orig} بـ ${used}`};
  }
  // english
  const m3 = s.match(/replaced.*?(2\s*[x×*]\s*)?(1[06]|6).*?(?:with|by).*?(2\s*[x×*]\s*)?(1[06]|6)/i) || s.match(/(2\s*[x×*]\s*)?(1[06]|6).*?instead of.*?(2\s*[x×*]\s*)?(1[06]|6)/i);
  if(m3){
    // need to be careful about order - try to infer
    const nums = s.match(/(1[06]|6)/g);
    if(nums && nums.length>=2){
      // common case: used first or second? look for "with 10"
      if(/with\s*(?:2\s*[x×*]\s*)?(1[06]|6)/i.test(s)){
        const um = s.match(/with\s*(?:2\s*[x×*]\s*)?(1[06]|6)/i);
        const om = s.match(/replaced\s*(?:2\s*[x×*]\s*)?(1[06]|6)/i) || s.match(/(?:2\s*[x×*]\s*)?(1[06]|6).*?instead/i);
        if(um && om){
          const used = '2x'+um[1], orig = '2x'+om[1];
          return {replaced:true, usedType:used, origType:orig, clear:true, reviewNeeded:false, reason:`استبدال ${orig} بـ ${used}`};
        }
      }
    }
  }
  // unclear
  if(/بدل|استبدال|replac/i.test(s) && /10|16|6/.test(s)){
    return {replaced:false, usedType:null, origType:null, clear:false, reviewNeeded:true, reason:'ملاحظة استبدال غير واضحة أو نوع بديل غير محدد'};
  }
  return {replaced:false, usedType:null, origType:null, clear:false, reviewNeeded:false, reason:''};
}

function dcExtractFromSidImport(importEntry){
  dcEnsureState();
  const site = trim(importEntry.site||'');
  const fileName = importEntry.fileName||'';
  const sheetName = importEntry.sheetName||'';
  const importedAt = importEntry.importedAt||new Date().toISOString();
  const signature = importEntry.signature||'';
  const rows = Array.isArray(importEntry.rows)?importEntry.rows:[];
  const items = [];
  const alerts = [];
  rows.forEach(r=>{
    const desc = r.productDescription || r.description || r.productCode || '';
    const req = Number(r.requested||0);
    if(req<=0) return;
    const foundType = dcCableTypeFromText(desc);
    const note = r.notes || r.note || '';
    const rep = dcDetectReplacement(note);
    if(foundType){
      if(rep.replaced && rep.usedType && rep.clear){
        items.push({
          origType: foundType,
          usedType: rep.usedType,
          qty: req,
          productDescription: desc,
          requestedQty: req,
          replaced: true,
          replacementNote: rep.reason || note,
          reviewNeeded: false,
          reviewReason: ''
        });
        return;
      }
      if(rep.reviewNeeded){
        alerts.push({id:nextId(), site, fileName, reason:'ملاحظة استبدال غير واضحة', detail:`${desc} - ${req} م - ${note}`, createdAt:new Date().toISOString(), resolved:false});
        items.push({
          origType: foundType,
          usedType: foundType,
          qty: req,
          productDescription: desc,
          requestedQty: req,
          replaced: false,
          replacementNote: note,
          reviewNeeded: true,
          reviewReason: rep.reason
        });
        return;
      }
      items.push({
        origType: foundType,
        usedType: foundType,
        qty: req,
        productDescription: desc,
        requestedQty: req,
        replaced: false,
        replacementNote: note||'',
        reviewNeeded: false,
        reviewReason: ''
      });
      return;
    } else {
      // check if note mentions cable replacement even if desc not clear
      if(rep.replaced && rep.usedType){
        alerts.push({id:nextId(), site, fileName, reason:'تعذّر التعرف على نوع الكابل من اسم المادة', detail:`${desc} - ${req} م - ملاحظة: ${note}`, createdAt:new Date().toISOString(), resolved:false});
        items.push({
          origType: null,
          usedType: rep.usedType,
          qty: req,
          productDescription: desc,
          requestedQty: req,
          replaced: true,
          replacementNote: rep.reason || note,
          reviewNeeded: true,
          reviewReason: 'تعذّر التعرف على النوع الأصلي من اسم المادة'
        });
        return;
      }
      alerts.push({id:nextId(), site, fileName, reason:'مادة DC لم يتم التعرف عليها أو كمية غير مؤكدة', detail:`${desc} - ${req} م`, createdAt:new Date().toISOString(), resolved:false});
      items.push({
        origType: null,
        usedType: null,
        qty: req,
        productDescription: desc,
        requestedQty: req,
        replaced: false,
        replacementNote: note||'',
        reviewNeeded: true,
        reviewReason: 'لم يتم التعرف على نوع كابل DC'
      });
    }
  });
  const totals = {qty6:0, qty10:0, qty16:0};
  items.forEach(it=>{
    if(it.reviewNeeded || it.usedType===null) return;
    if(it.usedType==='2x6') totals.qty6 += Number(it.qty||0);
    if(it.usedType==='2x10') totals.qty10 += Number(it.qty||0);
    if(it.usedType==='2x16') totals.qty16 += Number(it.qty||0);
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
    newList.push({
      id: 'DCC'+Date.now().toString(36)+Math.random().toString(36).slice(2,6)+Math.random().toString(36).slice(2,4),
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
  // avoid duplicating unresolved alerts by detail+site? simple approach - keep
  STATE.dcCables.consumption = newList;
  // merge alerts: don't duplicate same detail+site unresolved
  const seen = new Set();
  const merged = [];
  allAlerts.slice().reverse().forEach(a=>{
    const key = (a.site||'')+'|'+(a.detail||'')+'|'+(a.reason||'');
    if(seen.has(key)) return;
    seen.add(key);
    merged.push(a);
  });
  STATE.dcCables.alerts = merged.slice(0,200);
}
