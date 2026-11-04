/* واجهة إدارة كوابل DC داخل قسم رفع SID */
function dcGetAllCodesFromSid(){
  const set = new Map();
  (STATE.sidReview.imports||[]).forEach(imp=>{
    (imp.rows||[]).forEach(r=>{
      const code = String(r.productCode||'').trim();
      const desc = r.productDescription || r.description || '';
      if(code){
        const key = code.toLowerCase();
        if(!set.has(key)) set.set(key, {code, desc});
      }
    });
  });
  return Array.from(set.values()).sort((a,b)=>a.code.localeCompare(b.code));
}

function renderSidDcCablesSection(el){
  dcEnsureState();
  if(typeof dcRebuildConsumptionFromSid === 'function'){ try{ dcRebuildConsumptionFromSid(); }catch(e){} }
  const t = (function(){
    let r6=0,r10=0,r16=0;
    (STATE.dcCables.receipts||[]).forEach(rc=>{ r6+=Number(rc.qty6||0); r10+=Number(rc.qty10||0); r16+=Number(rc.qty16||0); });
    let c6=0,c10=0,c16=0;
    (STATE.dcCables.consumption||[]).forEach(cs=>{ if(cs.totals){ c6+=Number(cs.totals.qty6||0); c10+=Number(cs.totals.qty10||0); c16+=Number(cs.totals.qty16||0); } });
    return {received:{qty6:r6,qty10:r10,qty16:r16,total:r6+r10+r16}, consumed:{qty6:c6,qty10:c10,qty16:c16,total:c6+c10+c16}, remaining:{qty6:r6-c6,qty10:r10-c10,qty16:r16-c16,total:(r6+r10+r16)-(c6+c10+c16)}};
  })();
  const alerts = (STATE.dcCables.alerts||[]).filter(a=>!a.resolved);
  const maps = STATE.dcCables.mappings || {'6':[],'10':[],'16':[]};
  el.innerHTML = `
    <div class="panel">
      <h2>ربط أكواد مواد DC بالأنواع</h2>
      <div class="desc">يتم الحساب بناءً على أكواد المواد المرتبطة فقط، وليس بالاسم. لا يمكن ربط نفس الكود بأكثر من نوع.</div>
      <div class="grid3">
        <div class="panel" style="margin:0;">
          <h3>DC 6 mm² (2×6)</h3>
          <div class="btnrow"><button class="secondary" data-dc-pick="6">اختيار المواد</button></div>
          <div class="desc" style="margin-top:8px;">${(maps['6']||[]).length? (maps['6']||[]).map(c=>`<span class="pill" style="margin:2px;">${esc(c)}</span>`).join(''): '<span class="pill warn">لم يتم الربط بعد</span>'}</div>
        </div>
        <div class="panel" style="margin:0;">
          <h3>DC 10 mm² (2×10)</h3>
          <div class="btnrow"><button class="secondary" data-dc-pick="10">اختيار المواد</button></div>
          <div class="desc" style="margin-top:8px;">${(maps['10']||[]).length? (maps['10']||[]).map(c=>`<span class="pill" style="margin:2px;">${esc(c)}</span>`).join(''): '<span class="pill warn">لم يتم الربط بعد</span>'}</div>
        </div>
        <div class="panel" style="margin:0;">
          <h3>DC 16 mm² (2×16)</h3>
          <div class="btnrow"><button class="secondary" data-dc-pick="16">اختيار المواد</button></div>
          <div class="desc" style="margin-top:8px;">${(maps['16']||[]).length? (maps['16']||[]).map(c=>`<span class="pill" style="margin:2px;">${esc(c)}</span>`).join(''): '<span class="pill warn">لم يتم الربط بعد</span>'}</div>
        </div>
      </div>
    </div>

    <div class="panel">
      <h2>ملخص الأرصدة</h2>
      ${alerts.length?`<div class="msg warn"><b>حالات تحتاج مراجعة (${alerts.length})</b><ul style="margin:6px 0 0;padding-inline-start:20px;">${alerts.slice(0,8).map(a=>`<li>[${esc(a.site)}] ${esc(a.reason)} — ${esc(a.detail||'')}</li>`).join('')}</ul></div>`:''}
      <div class="tablewrap"><table class="data">
        <thead><tr><th>نوع الكابل</th><th>الكمية المستلمة (متر)</th><th>الكمية المستهلكة (متر)</th><th>المتبقي (متر)</th></tr></thead>
        <tbody>
          <tr><td>DC 6 mm²</td><td>${t.received.qty6}</td><td>${t.consumed.qty6}</td><td style="${t.remaining.qty6<0?'color:#b71c1c;font-weight:700':''}">${t.remaining.qty6}</td></tr>
          <tr><td>DC 10 mm²</td><td>${t.received.qty10}</td><td>${t.consumed.qty10}</td><td style="${t.remaining.qty10<0?'color:#b71c1c;font-weight:700':''}">${t.remaining.qty10}</td></tr>
          <tr><td>DC 16 mm²</td><td>${t.received.qty16}</td><td>${t.consumed.qty16}</td><td style="${t.remaining.qty16<0?'color:#b71c1c;font-weight:700':''}">${t.remaining.qty16}</td></tr>
          <tr style="font-weight:800;background:#fbfaf6;"><td>الإجمالي</td><td>${t.received.total}</td><td>${t.consumed.total}</td><td style="${t.remaining.total<0?'color:#b71c1c':''}">${t.remaining.total}</td></tr>
        </tbody>
      </table></div>
      <div class="btnrow" style="margin-top:12px;">
        <button class="primary" id="btnSidDcAddReceipt">➕ تسجيل استلام كوابل DC</button>
        <button class="secondary" id="btnSidDcRefresh">🔄 إعادة احتساب من ملفات SID</button>
        <button class="secondary" id="btnSidDcExport">📥 تصدير Excel</button>
      </div>
    </div>

    <div class="panel">
      <h2>استهلاك حسب المواقع</h2>
      <input type="text" id="sidDcSiteSearch" placeholder="بحث عن موقع..." style="max-width:260px;margin-bottom:10px;">
      <div class="tablewrap"><table class="data" id="sidDcSitesTable">
        <thead><tr><th>الموقع</th><th>DC 6 mm²</th><th>DC 10 mm²</th><th>DC 16 mm²</th><th>الإجمالي</th><th>إجراء</th></tr></thead>
        <tbody>
          ${(STATE.dcCables.consumption||[]).slice().sort((a,b)=>String(a.site).localeCompare(String(b.site))).map(cs=>{
            const tot = cs.totals||{qty6:0,qty10:0,qty16:0};
            const stot = (tot.qty6||0)+(tot.qty10||0)+(tot.qty16||0);
            const hasRev = (cs.items||[]).some(it=>it.reviewNeeded);
            return `<tr data-sdcs="${esc(cs.site)}"><td>${esc(cs.site)} ${hasRev?'<span class="pill warn">مراجعة</span>':''}</td><td>${tot.qty6||0}</td><td>${tot.qty10||0}</td><td>${tot.qty16||0}</td><td>${stot}</td><td><button class="secondary" data-sdcdet="${esc(cs.site)}">عرض التفاصيل</button></td></tr>`;
          }).join('') || '<tr><td colspan="6" class="empty">لا يوجد استهلاك بعد — اربط الأكواد ثم أعد الاحتساب بعد رفع ملفات SID</td></tr>'}
        </tbody>
      </table></div>
    </div>

    <div class="panel">
      <h2>سجل عمليات الاستلام</h2>
      <div class="tablewrap"><table class="data">
        <thead><tr><th>التاريخ</th><th>DC 6 mm²</th><th>DC 10 mm²</th><th>DC 16 mm²</th><th>الإجمالي</th><th>ملاحظات</th><th>إجراء</th></tr></thead>
        <tbody>
          ${(STATE.dcCables.receipts||[]).slice().reverse().map(rc=>{
            const tot = (Number(rc.qty6||0)+Number(rc.qty10||0)+Number(rc.qty16||0));
            return `<tr><td>${esc(rc.date||'')}</td><td>${rc.qty6||0}</td><td>${rc.qty10||0}</td><td>${rc.qty16||0}</td><td>${tot}</td><td>${esc(rc.notes||'')}</td><td><button class="secondary" data-sdcedit="${rc.id}">تعديل</button></td></tr>`;
          }).join('') || '<tr><td colspan="7" class="empty">لا توجد عمليات استلام بعد</td></tr>'}
        </tbody>
      </table></div>
    </div>
  `;

  el.querySelectorAll('[data-dc-pick]').forEach(btn=>{
    btn.addEventListener('click', ()=>dcOpenCodePicker(btn.dataset.dcPick));
  });
  document.getElementById('btnSidDcAddReceipt').addEventListener('click', ()=>dcOpenReceiptModalSid(null));
  document.getElementById('btnSidDcRefresh').addEventListener('click', async ()=>{
    if(typeof dcRebuildConsumptionFromSid === 'function'){ dcRebuildConsumptionFromSid(); await saveState(['dcCables']); }
    renderSidDcCablesSection(el);
    alert('تم إعادة الاحتساب بناءً على الأكواد المرتبطة');
  });
  document.getElementById('btnSidDcExport').addEventListener('click', dcExportExcelSid);
  const search = document.getElementById('sidDcSiteSearch');
  if(search){
    search.addEventListener('input', ()=>{
      const q = search.value.toLowerCase();
      document.querySelectorAll('#sidDcSitesTable tbody tr').forEach(tr=>{
        if(tr.querySelector('.empty')) return;
        tr.style.display = tr.textContent.toLowerCase().includes(q)?'':'none';
      });
    });
  }
  el.querySelectorAll('[data-sdcedit]').forEach(btn=>{
    btn.addEventListener('click', ()=>{
      const rc = (STATE.dcCables.receipts||[]).find(x=>x.id===btn.dataset.sdcedit);
      if(rc) dcOpenReceiptModalSid(rc);
    });
  });
  el.querySelectorAll('[data-sdcdet]').forEach(btn=>{
    btn.addEventListener('click', ()=>dcOpenSiteDetailSid(btn.dataset.sdcdet));
  });
}

function dcOpenCodePicker(sz){
  dcEnsureState();
  const codes = dcGetAllCodesFromSid();
  const current = new Set((STATE.dcCables.mappings[sz]||[]).map(c=>String(c).toLowerCase()));
  openModal(`اختيار أكواد المواد لـ DC ${sz} mm²`, (body)=>{
    body.innerHTML = `
      <div class="desc">اختر الأكواد المرتبطة بهذا النوع. لا يمكن ربط نفس الكود بنوع آخر.</div>
      <input type="text" id="dcPickSearch" placeholder="بحث بالكود أو الوصف..." style="margin:8px 0;">
      <div class="tablewrap" style="max-height:50vh;"><table class="data" id="dcPickTable">
        <thead><tr><th>اختيار</th><th>كود المادة</th><th>الوصف</th></tr></thead>
        <tbody>
          ${codes.map(c=>`<tr data-dcp-row><td><input type="checkbox" class="dcPickChk" data-code="${esc(c.code)}" ${current.has(c.code.toLowerCase())?'checked':''}></td><td>${esc(c.code)}</td><td>${esc(c.desc)}</td></tr>`).join('') || '<tr><td colspan="3" class="empty">لا توجد مواد في ملفات SID المرفوعة</td></tr>'}
        </tbody>
      </table></div>
      <div id="dcPickMsg"></div>
      <div class="btnrow"><button class="primary" id="dcPickSave">حفظ</button><button class="secondary" id="dcPickCancel">إلغاء</button></div>
    `;
    const search = document.getElementById('dcPickSearch');
    if(search){
      search.addEventListener('input', ()=>{
        const q = search.value.toLowerCase();
        document.querySelectorAll('#dcPickTable tbody tr[data-dcp-row]').forEach(tr=>{
          tr.style.display = tr.textContent.toLowerCase().includes(q)?'':'none';
        });
      });
    }
    document.getElementById('dcPickCancel').addEventListener('click', closeModal);
    document.getElementById('dcPickSave').addEventListener('click', async ()=>{
      // remove selected codes from other sizes
      const selected = [];
      document.querySelectorAll('.dcPickChk:checked').forEach(ch=>selected.push(String(ch.dataset.code).trim()));
      // check conflicts
      for(const s2 of ['6','10','16']){
        if(s2===sz) continue;
        for(const sc of selected){
          if((STATE.dcCables.mappings[s2]||[]).some(c=>String(c).trim().toLowerCase()===sc.toLowerCase())){
            document.getElementById('dcPickMsg').innerHTML = '<div class="msg bad">لا يمكن ربط نفس الكود بأكثر من نوع DC</div>';
            return;
          }
        }
      }
      // clear this size and add selected (also ensure not in others)
      STATE.dcCables.mappings[sz] = selected;
      ['6','10','16'].forEach(s2=>{
        if(s2===sz) return;
        STATE.dcCables.mappings[s2] = (STATE.dcCables.mappings[s2]||[]).filter(c=>{
          const cl = String(c).trim().toLowerCase();
          return !selected.some(sc=>sc.toLowerCase()===cl);
        });
      });
      await saveState(['dcCables']);
      closeModal();
      const el = document.getElementById('tabContent');
      if(el) renderSidDcCablesSection(el);
    });
  }, {maxWidth:'760px'});
}

function dcOpenReceiptModalSid(rc){
  const isEdit = !!rc;
  openModal(isEdit?'تعديل عملية استلام كوابل DC':'تسجيل استلام كوابل DC', (body)=>{
    body.innerHTML = `
      <div class="grid3">
        <div><label>تاريخ الاستلام</label><input type="date" id="sdcrDate" value="${esc(rc&&rc.date?rc.date:todayStr())}"></div>
        <div><label>DC 6 mm² (متر)</label><input type="number" id="sdcr6" step="0.001" min="0" value="${rc&&rc.qty6!=null?rc.qty6:''}"></div>
        <div><label>DC 10 mm² (متر)</label><input type="number" id="sdcr10" step="0.001" min="0" value="${rc&&rc.qty10!=null?rc.qty10:''}"></div>
      </div>
      <div class="grid3" style="margin-top:10px;">
        <div><label>DC 16 mm² (متر)</label><input type="number" id="sdcr16" step="0.001" min="0" value="${rc&&rc.qty16!=null?rc.qty16:''}"></div>
        <div style="grid-column:span 2"><label>ملاحظات</label><input type="text" id="sdcrNotes" value="${esc(rc&&rc.notes||'')}"></div>
      </div>
      <div class="btnrow"><button class="primary" id="sdcrSave">حفظ</button><button class="secondary" id="sdcrCancel">إلغاء</button></div>
    `;
    document.getElementById('sdcrCancel').addEventListener('click', closeModal);
    document.getElementById('sdcrSave').addEventListener('click', async ()=>{
      const qty6 = Number(document.getElementById('sdcr6').value||0);
      const qty10 = Number(document.getElementById('sdcr10').value||0);
      const qty16 = Number(document.getElementById('sdcr16').value||0);
      const date = document.getElementById('sdcrDate').value||todayStr();
      const notes = document.getElementById('sdcrNotes').value||'';
      dcEnsureState();
      if(isEdit){
        const idx = STATE.dcCables.receipts.findIndex(x=>x.id===rc.id);
        if(idx>=0) STATE.dcCables.receipts[idx] = {...STATE.dcCables.receipts[idx], date, qty6, qty10, qty16, notes};
      }else{
        STATE.dcCables.receipts.push({id:nextId(), date, qty6, qty10, qty16, total: qty6+qty10+qty16, notes, createdAt:new Date().toISOString()});
      }
      await saveState(['dcCables']);
      closeModal();
      const el = document.getElementById('tabContent');
      if(el) renderSidDcCablesSection(el);
    });
  }, {maxWidth:'620px'});
}

function dcOpenSiteDetailSid(site){
  dcEnsureState();
  if(typeof dcRebuildConsumptionFromSid === 'function'){ try{ dcRebuildConsumptionFromSid(); }catch(e){} }
  const cs = (STATE.dcCables.consumption||[]).find(x=>x.site===site);
  openModal('تفاصيل استهلاك الموقع: '+site, (body)=>{
    if(!cs){ body.innerHTML = '<div class="msg warn">لا توجد بيانات</div>'; return; }
    body.innerHTML = `
      <div class="tablewrap"><table class="data">
        <thead><tr><th>كود المادة</th><th>الوصف</th><th>النوع المطلوب أصلاً</th><th>النوع المستخدم فعلياً</th><th>الكمية</th><th>استبدال</th><th>ملاحظة</th><th>حالة</th></tr></thead>
        <tbody>
          ${(cs.items||[]).map(it=>`<tr><td>${esc(it.productCode||'')}</td><td>${esc(it.productDescription||'')}</td><td>${esc(it.origSize?('DC '+it.origSize+' mm²'):'')}</td><td>${esc(it.usedSize?('DC '+it.usedSize+' mm²'):'')}</td><td>${it.qty||0}</td><td>${it.replaced?'نعم':'لا'}</td><td>${esc(it.replacementNote||'')}</td><td>${it.reviewNeeded?'<span class="pill warn">مراجعة</span>':'<span class="pill ok">مُعتمد</span>'}</td></tr>`).join('')}
        </tbody>
      </table></div>
      <div class="btnrow"><button class="secondary" id="sdcdClose">إغلاق</button></div>
    `;
    document.getElementById('sdcdClose').addEventListener('click', closeModal);
  }, {maxWidth:'1100px'});
}

function dcExportExcelSid(){
  dcEnsureState();
  if(typeof dcRebuildConsumptionFromSid === 'function'){ try{ dcRebuildConsumptionFromSid(); }catch(e){} }
  let r6=0,r10=0,r16=0; (STATE.dcCables.receipts||[]).forEach(rc=>{ r6+=Number(rc.qty6||0); r10+=Number(rc.qty10||0); r16+=Number(rc.qty16||0); });
  let c6=0,c10=0,c16=0; (STATE.dcCables.consumption||[]).forEach(cs=>{ if(cs.totals){ c6+=Number(cs.totals.qty6||0); c10+=Number(cs.totals.qty10||0); c16+=Number(cs.totals.qty16||0); } });
  const sheets = [];
  sheets.push({name: safeSheetName('ملخص'), ws: aoaSheet([
    ['نوع الكابل','الكمية المستلمة','الكمية المستهلكة','المتبقي'],
    ['DC 6 mm²', r6,c6,r6-c6],
    ['DC 10 mm²', r10,c10,r10-c10],
    ['DC 16 mm²', r16,c16,r16-c16],
    ['الإجمالي', r6+r10+r16,c6+c10+c16,(r6+r10+r16)-(c6+c10+c16)],
  ],[16,18,18,18])});
  const s2 = [['اسم الموقع','DC 6 mm²','DC 10 mm²','DC 16 mm²','الإجمالي']];
  (STATE.dcCables.consumption||[]).slice().sort((a,b)=>String(a.site).localeCompare(String(b.site))).forEach(cs=>{
    const tot = cs.totals||{qty6:0,qty10:0,qty16:0};
    s2.push([cs.site, tot.qty6||0, tot.qty10||0, tot.qty16||0, (tot.qty6||0)+(tot.qty10||0)+(tot.qty16||0)]);
  });
  sheets.push({name: safeSheetName('استهلاك المواقع'), ws: aoaSheet(s2,[30,14,14,14,16])});
  const s3 = [['نوع','كود المادة']];
  (STATE.dcCables.mappings['6']||[]).forEach(c=>s3.push(['DC 6 mm²', c]));
  (STATE.dcCables.mappings['10']||[]).forEach(c=>s3.push(['DC 10 mm²', c]));
  (STATE.dcCables.mappings['16']||[]).forEach(c=>s3.push(['DC 16 mm²', c]));
  sheets.push({name: safeSheetName('أكواد مرتبطة'), ws: aoaSheet(s3,[16,20])});
  downloadWorkbook(sheets, `كوابل_DC_${todayStr()}.xlsx`);
}
