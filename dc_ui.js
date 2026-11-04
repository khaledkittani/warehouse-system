/* واجهة إدارة كوابل DC */
function dcCalcTotals(){
  dcEnsureState();
  let r6=0,r10=0,r16=0;
  (STATE.dcCables.receipts||[]).forEach(rc=>{
    r6 += Number(rc.qty6||0); r10 += Number(rc.qty10||0); r16 += Number(rc.qty16||0);
  });
  let c6=0,c10=0,c16=0;
  (STATE.dcCables.consumption||[]).forEach(cs=>{
    if(cs.totals){
      c6 += Number(cs.totals.qty6||0); c10 += Number(cs.totals.qty10||0); c16 += Number(cs.totals.qty16||0);
    }
  });
  return {
    received:{qty6:r6,qty10:r10,qty16:r16, total:r6+r10+r16},
    consumed:{qty6:c6,qty10:c10,qty16:c16, total:c6+c10+c16},
    remaining:{qty6:r6-c6, qty10:r10-c10, qty16:r16-c16, total:(r6+r10+r16)-(c6+c10+c16)}
  };
}

function renderDcCablesTab(el){
  dcEnsureState();
  if(typeof dcRebuildConsumptionFromSid === 'function'){
    try{ dcRebuildConsumptionFromSid(); }catch(e){}
  }
  const t = dcCalcTotals();
  const alerts = (STATE.dcCables.alerts||[]).filter(a=>!a.resolved);
  el.innerHTML = `
    <div class="panel">
      <h2>إدارة كوابل DC</h2>
      <div class="desc">متكاملة مع رفع ملفات SID — الاستهلاك يُحسب تلقائياً من الكمية المطلوبة مع مراعاة استبدال النوع حسب ملاحظات SID.</div>
      ${alerts.length?`<div class="msg warn"><b>حالات تحتاج مراجعة (${alerts.length})</b><ul style="margin:6px 0 0;padding-inline-start:20px;">${alerts.slice(0,10).map(a=>`<li>[${esc(a.site)}] ${esc(a.reason)} — ${esc(a.detail||'')}</li>`).join('')}</ul>${alerts.length>10?`<div style="margin-top:4px;">و${alerts.length-10} أخرى...</div>`:''}</div>`:''}
      <h3 style="margin:16px 0 10px;">ملخص الأرصدة</h3>
      <div class="tablewrap"><table class="data">
        <thead><tr><th>نوع الكابل</th><th>الكمية المستلمة (متر)</th><th>الكمية المستهلكة (متر)</th><th>الكمية المتبقية (متر)</th></tr></thead>
        <tbody>
          <tr><td>2×6 mm²</td><td>${fmtNum(t.received.qty6)}</td><td>${fmtNum(t.consumed.qty6)}</td><td style="${t.remaining.qty6<0?'color:#b71c1c;font-weight:700':''}">${fmtNum(t.remaining.qty6)}</td></tr>
          <tr><td>2×10 mm²</td><td>${fmtNum(t.received.qty10)}</td><td>${fmtNum(t.consumed.qty10)}</td><td style="${t.remaining.qty10<0?'color:#b71c1c;font-weight:700':''}">${fmtNum(t.remaining.qty10)}</td></tr>
          <tr><td>2×16 mm²</td><td>${fmtNum(t.received.qty16)}</td><td>${fmtNum(t.consumed.qty16)}</td><td style="${t.remaining.qty16<0?'color:#b71c1c;font-weight:700':''}">${fmtNum(t.remaining.qty16)}</td></tr>
          <tr style="font-weight:800;background:#fbfaf6;"><td>الإجمالي</td><td>${fmtNum(t.received.total)}</td><td>${fmtNum(t.consumed.total)}</td><td style="${t.remaining.total<0?'color:#b71c1c':''}">${fmtNum(t.remaining.total)}</td></tr>
        </tbody>
      </table></div>
      ${t.remaining.total<0?`<div class="msg bad" style="margin-top:8px;">تحذير: الاستهلاك تجاوز الكمية المستلمة</div>`:''}
      <div class="btnrow" style="margin-top:12px;">
        <button class="primary" id="btnDcAddReceipt">➕ تسجيل استلام كوابل DC</button>
        <button class="secondary" id="btnDcRefresh">🔄 تحديث من ملفات SID</button>
        <button class="secondary" id="btnDcExport">📥 تصدير Excel</button>
      </div>
    </div>

    <div class="panel">
      <h2>استهلاك حسب المواقع</h2>
      <div style="display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-bottom:10px;">
        <input type="text" id="dcSiteSearch" placeholder="بحث عن موقع..." style="max-width:260px;">
        <div class="desc">يعرض الاستهلاك الفعلي بعد مراعاة الاستبدال</div>
      </div>
      <div class="tablewrap"><table class="data" id="dcSitesTable">
        <thead><tr><th>اسم الموقع</th><th>2×6 mm²</th><th>2×10 mm²</th><th>2×16 mm²</th><th>إجمالي الاستهلاك</th><th>إجراء</th></tr></thead>
        <tbody>
          ${(STATE.dcCables.consumption||[]).slice().sort((a,b)=>String(a.site).localeCompare(String(b.site))).map(cs=>{
            const tot = cs.totals||{qty6:0,qty10:0,qty16:0};
            const stot = (tot.qty6||0)+(tot.qty10||0)+(tot.qty16||0);
            const hasRev = (cs.items||[]).some(it=>it.reviewNeeded);
            return `<tr data-dcs="${esc(cs.site)}"><td>${esc(cs.site)} ${hasRev?'<span class="pill warn">مراجعة</span>':''}</td><td>${fmtNum(tot.qty6||0)}</td><td>${fmtNum(tot.qty10||0)}</td><td>${fmtNum(tot.qty16||0)}</td><td>${fmtNum(stot)}</td><td><button class="secondary" data-dcdet="${esc(cs.site)}">عرض التفاصيل</button></td></tr>`;
          }).join('') || '<tr><td colspan="6" class="empty">لا يوجد استهلاك بعد — ارفع ملفات SID ليتم الحساب تلقائياً</td></tr>'}
        </tbody>
      </table></div>
    </div>

    <div class="panel">
      <h2>سجل عمليات الاستلام</h2>
      <div class="tablewrap"><table class="data">
        <thead><tr><th>التاريخ</th><th>2×6 mm²</th><th>2×10 mm²</th><th>2×16 mm²</th><th>الإجمالي</th><th>ملاحظات</th><th>إجراء</th></tr></thead>
        <tbody>
          ${(STATE.dcCables.receipts||[]).slice().reverse().map(rc=>{
            const tot = (Number(rc.qty6||0)+Number(rc.qty10||0)+Number(rc.qty16||0));
            return `<tr><td>${esc(rc.date||'')}</td><td>${fmtNum(rc.qty6||0)}</td><td>${fmtNum(rc.qty10||0)}</td><td>${fmtNum(rc.qty16||0)}</td><td>${fmtNum(tot)}</td><td>${esc(rc.notes||'')}</td><td><button class="secondary" data-dcedit="${rc.id}">تعديل</button></td></tr>`;
          }).join('') || '<tr><td colspan="7" class="empty">لا توجد عمليات استلام بعد</td></tr>'}
        </tbody>
      </table></div>
    </div>
  `;

  document.getElementById('btnDcAddReceipt').addEventListener('click', ()=>dcOpenReceiptModal(null));
  document.getElementById('btnDcRefresh').addEventListener('click', async ()=>{
    if(typeof dcRebuildConsumptionFromSid === 'function'){ dcRebuildConsumptionFromSid(); await saveState(['dcCables']); }
    renderDcCablesTab(el);
    alert('تم تحديث الاستهلاك من ملفات SID الحالية');
  });
  document.getElementById('btnDcExport').addEventListener('click', dcExportExcel);

  const search = document.getElementById('dcSiteSearch');
  if(search){
    search.addEventListener('input', ()=>{
      const q = search.value.toLowerCase();
      document.querySelectorAll('#dcSitesTable tbody tr').forEach(tr=>{
        if(tr.querySelector('.empty')) return;
        const txt = tr.textContent.toLowerCase();
        tr.style.display = txt.includes(q)?'':'none';
      });
    });
  }
  document.querySelectorAll('[data-dcedit]').forEach(btn=>{
    btn.addEventListener('click', ()=>{
      const id = btn.dataset.dcedit;
      const rc = (STATE.dcCables.receipts||[]).find(x=>x.id===id);
      if(rc) dcOpenReceiptModal(rc);
    });
  });
  document.querySelectorAll('[data-dcdet]').forEach(btn=>{
    btn.addEventListener('click', ()=>{
      const site = btn.dataset.dcdet;
      dcOpenSiteDetail(site);
    });
  });
}

function dcOpenReceiptModal(rc){
  const isEdit = !!rc;
  openModal(isEdit?'تعديل عملية استلام كوابل DC':'تسجيل استلام كوابل DC', (body)=>{
    body.innerHTML = `
      <div class="grid3">
        <div><label>تاريخ الاستلام</label><input type="date" id="dcrDate" value="${esc(rc&&rc.date?rc.date:todayStr())}"></div>
        <div><label>2×6 mm² (متر)</label><input type="number" id="dcr6" step="0.001" min="0" value="${rc&&rc.qty6!=null?rc.qty6:''}"></div>
        <div><label>2×10 mm² (متر)</label><input type="number" id="dcr10" step="0.001" min="0" value="${rc&&rc.qty10!=null?rc.qty10:''}"></div>
      </div>
      <div class="grid3" style="margin-top:10px;">
        <div><label>2×16 mm² (متر)</label><input type="number" id="dcr16" step="0.001" min="0" value="${rc&&rc.qty16!=null?rc.qty16:''}"></div>
        <div style="grid-column:span 2"><label>ملاحظات</label><input type="text" id="dcrNotes" value="${esc(rc&&rc.notes||'')}"></div>
      </div>
      <div id="dcrMsg"></div>
      <div class="btnrow"><button class="primary" id="dcrSave">حفظ</button><button class="secondary" id="dcrCancel">إلغاء</button></div>
    `;
    document.getElementById('dcrCancel').addEventListener('click', closeModal);
    document.getElementById('dcrSave').addEventListener('click', async ()=>{
      const qty6 = Number(document.getElementById('dcr6').value||0);
      const qty10 = Number(document.getElementById('dcr10').value||0);
      const qty16 = Number(document.getElementById('dcr16').value||0);
      const date = document.getElementById('dcrDate').value||todayStr();
      const notes = document.getElementById('dcrNotes').value||'';
      dcEnsureState();
      if(isEdit){
        const idx = STATE.dcCables.receipts.findIndex(x=>x.id===rc.id);
        if(idx>=0){
          STATE.dcCables.receipts[idx] = {...STATE.dcCables.receipts[idx], date, qty6, qty10, qty16, notes};
        }
      }else{
        STATE.dcCables.receipts.push({id:nextId(), date, qty6, qty10, qty16, total: qty6+qty10+qty16, notes, createdAt:new Date().toISOString()});
      }
      await saveState(['dcCables']);
      closeModal();
      if(typeof renderDcCablesTab === 'function' && document.getElementById('tabContent')) renderDcCablesTab(document.getElementById('tabContent'));
    });
  }, {maxWidth:'620px'});
}

function dcOpenSiteDetail(site){
  dcEnsureState();
  if(typeof dcRebuildConsumptionFromSid === 'function'){ try{ dcRebuildConsumptionFromSid(); }catch(e){} }
  const cs = (STATE.dcCables.consumption||[]).find(x=>x.site===site);
  openModal('تفاصيل استهلاك الموقع: '+site, (body)=>{
    if(!cs){
      body.innerHTML = '<div class="msg warn">لا توجد بيانات استهلاك لهذا الموقع</div>';
      return;
    }
    body.innerHTML = `
      <div class="tablewrap"><table class="data">
        <thead><tr><th>اسم المادة (الوصف)</th><th>النوع المطلوب أصلاً</th><th>النوع المستخدم فعلياً</th><th>الكمية (متر)</th><th>استبدال</th><th>ملاحظة الاستبدال</th><th>حالة</th></tr></thead>
        <tbody>
          ${(cs.items||[]).map(it=>{
            return `<tr><td>${esc(it.productDescription||'')}</td><td>${esc(it.origType||'-')}</td><td>${esc(it.usedType||'-')}</td><td>${fmtNum(it.qty||0)}</td><td>${it.replaced?'نعم':'لا'}</td><td>${esc(it.replacementNote||'')}</td><td>${it.reviewNeeded?'<span class="pill warn">يحتاج مراجعة</span>':'<span class="pill ok">مُعتمد</span>'}</td></tr>`;
          }).join('')}
        </tbody>
      </table></div>
      <div class="btnrow"><button class="secondary" id="dcdClose">إغلاق</button></div>
    `;
    document.getElementById('dcdClose').addEventListener('click', closeModal);
  }, {maxWidth:'980px'});
}

function dcExportExcel(){
  dcEnsureState();
  if(typeof dcRebuildConsumptionFromSid === 'function'){ try{ dcRebuildConsumptionFromSid(); }catch(e){} }
  const t = dcCalcTotals();
  const sheets = [];
  // Sheet 1: summary
  sheets.push({name: safeSheetName('ملخص الأرصدة'), ws: aoaSheet([
    ['نوع الكابل','إجمالي الكمية المستلمة','إجمالي الكمية المستهلكة','الكمية المتبقية'],
    ['2×6 mm²', t.received.qty6, t.consumed.qty6, t.remaining.qty6],
    ['2×10 mm²', t.received.qty10, t.consumed.qty10, t.remaining.qty10],
    ['2×16 mm²', t.received.qty16, t.consumed.qty16, t.remaining.qty16],
    ['الإجمالي', t.received.total, t.consumed.total, t.remaining.total],
  ],[20,18,18,18])});
  // Sheet 2: consumption by site
  const s2 = [['اسم الموقع','استهلاك 2×6','استهلاك 2×10','استهلاك 2×16','إجمالي استهلاك الموقع']];
  (STATE.dcCables.consumption||[]).slice().sort((a,b)=>String(a.site).localeCompare(String(b.site))).forEach(cs=>{
    const tot = cs.totals||{qty6:0,qty10:0,qty16:0};
    s2.push([cs.site, tot.qty6||0, tot.qty10||0, tot.qty16||0, (tot.qty6||0)+(tot.qty10||0)+(tot.qty16||0)]);
  });
  sheets.push({name: safeSheetName('استهلاك المواقع'), ws: aoaSheet(s2,[30,16,16,16,18])});
  // Sheet 3: details
  const s3 = [['اسم الموقع','نوع الكابل المطلوب في SID','نوع الكابل المستخدم فعلياً','الكمية المستهلكة','ملاحظات الاستبدال','يحتاج مراجعة']];
  (STATE.dcCables.consumption||[]).forEach(cs=>{
    (cs.items||[]).forEach(it=>{
      s3.push([cs.site, it.origType||'', it.usedType||'', it.qty||0, it.replacementNote||'', it.reviewNeeded?'نعم':'لا']);
    });
  });
  sheets.push({name: safeSheetName('تفاصيل الاستهلاك والاستبدال'), ws: aoaSheet(s3,[30,20,20,16,40,14])});
  downloadWorkbook(sheets, `كوابل_DC_${todayStr()}.xlsx`);
}
