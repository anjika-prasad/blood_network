const $ = (s, r = document) => r.querySelector(s);
const esc = v => v == null ? '' : String(v).replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

let meta = { hospitals: [], groups: [] };
const unitFilter = { hospital_id: '', group_id: '', status: '' };

// ---------- helpers ----------------------------------------------------
async function api(path, body) {
  const opt = body === undefined ? {} :
    { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
  let res;
  try { res = await fetch('/api' + path, opt); }
  catch { throw new Error('The local server is not running. Start it with: python server.py'); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
  return data;
}

const dateFmt = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
const timeFmt = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
const day = v => v ? dateFmt.format(new Date(v)) : '<span class="muted">–</span>';
const when = v => v ? timeFmt.format(new Date(v)) : '<span class="muted">–</span>';

const TONE = {
  AVAILABLE: 'ok', NEAR_EXPIRY: 'warn', IN_TRANSIT: 'info', EXPIRED: 'bad',
  PENDING: 'warn', PARTIAL: 'warn', TRANSFER_PENDING: 'info', FULFILLED: 'ok',
  RECEIVED: 'ok', CRITICAL: 'bad', URGENT: 'warn',
};
const words = s => { s = String(s).replace(/_/g, ' ').toLowerCase(); return s[0].toUpperCase() + s.slice(1); };
const pill = s => s ? `<span class="pill ${TONE[s] || ''}">${esc(words(s))}</span>` : '';

const options = (list, value, label, placeholder) =>
  (placeholder ? `<option value="">${esc(placeholder)}</option>` : '') +
  list.map(o => `<option value="${esc(o[value])}">${esc(o[label])}</option>`).join('');
const hospitalOptions = ph => options(meta.hospitals, 'hospital_id', 'hospital_name', ph);
const groupOptions = ph => options(meta.groups, 'group_id', 'group_name', ph);

// cols: [{ label, key | html(row), num }]
function table(cols, data, { id = '', empty = 'Nothing to show yet.' } = {}) {
  const head = cols.map(c => `<th${c.num ? ' class="num"' : ''}>${esc(c.label)}</th>`).join('');
  const body = data.length ? data.map(r => '<tr>' + cols.map(c =>
    `<td class="${c.num ? 'num' : ''}${c.cls ? ' ' + c.cls : ''}">${c.html ? c.html(r) : esc(r[c.key])}</td>`).join('') + '</tr>').join('')
    : `<tr><td class="empty" colspan="${cols.length}">${esc(empty)}</td></tr>`;
  return `<div class="scroll"><table><thead><tr>${head}</tr></thead><tbody id="${id}">${body}</tbody></table></div>`;
}

const card = (title, sub, inner) =>
  `<div class="card"><header><h2>${esc(title)}</h2>${sub ? `<p>${sub}</p>` : ''}</header>${inner}</div>`;

let toastTimer;
function toast(msg, isError) {
  const t = $('#toast');
  t.textContent = msg;
  t.className = 'show' + (isError ? ' error' : '');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.className = ''; }, isError ? 6000 : 3500);
}

function dialog(html) {
  const d = $('#dlg');
  d.innerHTML = html;
  if (!d.open) d.showModal();
}

const requestSummary = r =>
  `Request #${r.request_id} is ${words(r.status).toLowerCase()}: ${r.allocated} of ${r.units_required} unit(s) issued` +
  (r.in_transit ? `, ${r.in_transit} on the way from another hospital` : '');

// ---------- views ------------------------------------------------------
const views = {
  overview: {
    title: 'Overview', sub: 'Live stock, shortages and expiry risk across the network',
    async render() {
      const d = await api('/dashboard');
      const s = d.stats;
      const stats = [
        [s.usable_units, 'Usable units'], [s.expiring_soon, 'Expiring within 7 days', s.expiring_soon > 0],
        [s.open_requests, 'Open requests'], [s.in_transit, 'Transfers in transit'],
      ].map(([n, label, alert]) => `<div class="card stat${alert ? ' alert' : ''}"><b>${esc(n)}</b><span>${label}</span></div>`).join('');

      const names = meta.groups.map(g => g.group_name);
      const byHospital = new Map();
      for (const r of d.stock) {
        if (!byHospital.has(r.hospital_name)) byHospital.set(r.hospital_name, {});
        byHospital.get(r.hospital_name)[r.group_name] = r;
      }
      const net = Object.fromEntries(d.network.map(n => [n.group_name, n]));
      const matrix = `<div class="scroll"><table class="matrix"><thead><tr><th></th>${names.map(n => `<th>${esc(n)}</th>`).join('')}</tr></thead><tbody>` +
        [...byHospital].map(([h, cells]) => `<tr><td>${esc(h)}</td>` + names.map(n => {
          const c = cells[n];
          return c ? `<td><span class="cell ${esc(c.stock_flag)}" title="${esc(`${words(c.stock_flag)} · open demand ${c.open_demand} · keep between ${c.min_level} and ${c.max_level}`)}">${esc(c.usable_units)}</span></td>` : '<td></td>';
        }).join('') + '</tr>').join('') +
        `<tr class="total"><td>Network total</td>${names.map(n => `<td>${esc(net[n]?.network_usable ?? 0)}</td>`).join('')}</tr></tbody></table></div>`;
      const legend = `<span class="legend"><span><i style="background:var(--bad)"></i>Shortage</span><span><i style="background:var(--ok)"></i>Within range</span><span><i style="background:var(--info)"></i>Surplus</span></span>`;

      const expiring = table([
        { label: 'Unit', html: r => unitLink(r.unit_id) }, { label: 'Group', key: 'group_name' },
        { label: 'Hospital', key: 'hospital_name' }, { label: 'Expires', html: r => day(r.expiry_date) },
        { label: 'Days left', key: 'days_to_expiry', num: true },
      ], d.expiring, { empty: 'No usable units expire in the next 7 days.' });

      const wastage = table([
        { label: 'Hospital', key: 'hospital_name' }, { label: 'Issued', key: 'units_issued', num: true },
        { label: 'Expired', key: 'units_expired', num: true },
        { label: 'Wastage', num: true, html: r => r.wastage_pct == null ? '<span class="muted">–</span>' : esc(r.wastage_pct) + '%' },
        { label: '', html: r => `<div class="bar"><i style="width:${Math.min(100, Number(r.wastage_pct) || 0)}%"></i></div>` },
      ], d.wastage);

      return `<div class="stats">${stats}</div>` +
        card('Usable units by hospital and group', legend, matrix) +
        `<div class="cols">${card('Expiring soonest', 'Use or move these first', expiring)}${card('Wastage', 'Expired ÷ (expired + issued)', wastage)}</div>`;
    },
  },

  inventory: {
    title: 'Inventory', sub: 'Every blood unit, soonest expiry first',
    async render() {
      const q = new URLSearchParams(Object.entries(unitFilter).filter(([, v]) => v));
      const data = await api('/units?' + q);
      const statuses = ['AVAILABLE', 'NEAR_EXPIRY', 'IN_TRANSIT', 'ISSUED', 'EXPIRED', 'DISCARDED'].map(s => ({ v: s, l: words(s) }));
      const filters = `<div class="filters">
        <select data-filter="hospital_id" aria-label="Hospital">${hospitalOptions('All hospitals')}</select>
        <select data-filter="group_id" aria-label="Blood group">${groupOptions('All groups')}</select>
        <select data-filter="status" aria-label="Status">${options(statuses, 'v', 'l', 'Any status')}</select></div>`;
      const list = table([
        { label: 'Unit', html: r => unitLink(r.unit_id) }, { label: 'Group', key: 'group_name' },
        { label: 'Hospital', key: 'hospital_name' }, { label: 'Collected', html: r => day(r.collection_date) },
        { label: 'Expires', html: r => day(r.expiry_date) }, { label: 'Days left', key: 'days_to_expiry', num: true },
        { label: 'Status', html: r => pill(r.status) },
      ], data, { empty: 'No units match these filters.' });
      return card(`${data.length}${data.length === 500 ? '+' : ''} unit${data.length === 1 ? '' : 's'}`, 'Select a unit number for its history or to move it', filters) + card('Units', '', list);
    },
    after() { for (const [k, v] of Object.entries(unitFilter)) $(`[data-filter="${k}"]`).value = v; },
  },

  donors: {
    title: 'Donors', sub: 'Register donors and record donations',
    async render() {
      const data = await api('/donors');
      const today = new Date().toISOString().slice(0, 10);
      const form = `<form class="form" data-form="donor">
        <label>Full name<input name="full_name" maxlength="100" required></label>
        <label>Date of birth<input name="date_of_birth" type="date" max="${today}" required></label>
        <label>Gender<select name="gender" required><option value="">Choose…</option><option value="F">Female</option><option value="M">Male</option><option value="O">Other</option></select></label>
        <label>Phone<input name="phone" maxlength="15" inputmode="tel" required></label>
        <label>Blood group<select name="group_id" required>${groupOptions('Choose…')}</select></label>
        <button class="btn">Register donor</button></form>`;
      const list = table([
        { label: 'Donor', key: 'full_name' }, { label: 'Group', key: 'group_name' }, { label: 'Phone', key: 'phone' },
        { label: 'Born', html: r => day(r.date_of_birth) }, { label: 'Last donation', html: r => day(r.last_donation_date) },
        { label: 'Units', key: 'units_donated', num: true },
        { label: '', cls: 'act', html: r => `<button class="btn ghost small" data-act="donate" data-id="${esc(r.donor_id)}" data-name="${esc(r.full_name)}">Record donation</button>` },
      ], data, { id: 'donor-rows' });
      return card('Register a donor', '', form) +
        card(`${data.length} donor${data.length === 1 ? '' : 's'}`, '', `<div class="filters" style="margin-bottom:16px"><input data-search="donor-rows" type="search" placeholder="Search name, phone or group" aria-label="Search donors"></div>${list}`);
    },
  },

  requests: {
    title: 'Requests', sub: 'Raise a patient request and allocate blood, soonest expiry first',
    async render() {
      const data = await api('/requests');
      const form = `<form class="form" data-form="request">
        <label>Hospital<select name="hospital_id" required>${hospitalOptions('Choose…')}</select></label>
        <label>Patient reference<input name="patient_ref" maxlength="30" placeholder="MRN-00042" required></label>
        <label>Patient blood group<select name="group_id" required>${groupOptions('Choose…')}</select></label>
        <label>Units required<input name="units_required" type="number" min="1" max="99" value="1" required></label>
        <label>Urgency<select name="urgency"><option value="ROUTINE">Routine</option><option value="URGENT">Urgent</option><option value="CRITICAL">Critical</option></select></label>
        <label class="check"><input type="checkbox" name="allocate" checked>Allocate immediately</label>
        <button class="btn">Create request</button></form>`;
      const open = new Set(['PENDING', 'PARTIAL', 'TRANSFER_PENDING']);
      const list = table([
        { label: '#', key: 'request_id' }, { label: 'Patient', key: 'patient_ref' }, { label: 'Hospital', key: 'hospital_name' },
        { label: 'Group', key: 'group_name' },
        { label: 'Issued', num: true, html: r => `${esc(r.allocated)} / ${esc(r.units_required)}` + (r.in_transit ? ` <span class="muted">+${esc(r.in_transit)} in transit</span>` : '') },
        { label: 'Urgency', html: r => pill(r.urgency) }, { label: 'Status', html: r => pill(r.status) },
        { label: 'Requested', html: r => when(r.request_time) },
        { label: 'Minutes', num: true, html: r => r.minutes_to_fulfil == null ? '<span class="muted">–</span>' : esc(r.minutes_to_fulfil) },
        { label: '', cls: 'act', html: r => open.has(r.status) && r.allocated + r.in_transit < r.units_required ? `<button class="btn ghost small" data-act="allocate" data-id="${esc(r.request_id)}">Allocate</button>` : '' },
      ], data);
      return card('New request', '', form) + card('All requests', 'Newest first', list);
    },
  },

  transfers: {
    title: 'Transfers', sub: 'Units moving between hospitals',
    async render() {
      const data = await api('/transfers');
      return card('Transfers', 'In transit first. Confirm arrival to issue or restock the unit.', table([
        { label: '#', key: 'transfer_id' }, { label: 'Unit', html: r => unitLink(r.unit_id) }, { label: 'Group', key: 'group_name' },
        { label: 'From', key: 'from_hospital' }, { label: 'To', key: 'to_hospital' },
        { label: 'For', html: r => r.request_id ? `Request #${esc(r.request_id)}` : '<span class="muted">Rebalancing</span>' },
        { label: 'Sent', html: r => when(r.initiated_at) }, { label: 'Received', html: r => when(r.received_at) },
        { label: 'Status', html: r => pill(r.status) },
        { label: '', cls: 'act', html: r => r.status === 'IN_TRANSIT' ? `<button class="btn ghost small" data-act="receive" data-id="${esc(r.transfer_id)}">Confirm arrival</button>` : '' },
      ], data, { empty: 'No transfers yet. They appear when a request cannot be covered locally, or when you move a unit from Inventory.' }));
    },
  },

  activity: {
    title: 'Activity', sub: 'Expiry sweeps and the audit trail of unit status changes',
    async render() {
      const d = await api('/activity');
      const sweeps = table([
        { label: 'Run at', html: r => when(r.run_time) }, { label: 'Flagged near expiry', key: 'flagged_near_expiry', num: true },
        { label: 'Marked expired', key: 'marked_expired', num: true },
      ], d.sweeps, { empty: 'The sweep has not run yet.' });
      const changes = table([
        { label: 'When', html: r => when(r.changed_at) }, { label: 'Unit', html: r => unitLink(r.unit_id) },
        { label: 'From', html: r => r.old_status ? pill(r.old_status) : '<span class="muted">New unit</span>' },
        { label: 'To', html: r => pill(r.new_status) },
      ], d.changes);
      return `<div class="cols">${card('Expiry sweep', '<button class="btn small" data-act="sweep">Run sweep now</button>', sweeps)}${card('Recent status changes', 'Latest 60', changes)}</div>`;
    },
  },
};

const unitLink = id => `<button class="link" data-act="unit" data-id="${esc(id)}">#${esc(id)}</button>`;

let routeToken = 0;
async function route() {
  const name = views[location.hash.slice(1)] ? location.hash.slice(1) : 'overview';
  const v = views[name], view = $('#view'), token = ++routeToken;
  document.querySelectorAll('#nav a').forEach(a => a.classList.toggle('on', a.hash === '#' + name));
  $('#title').textContent = v.title;
  $('#subtitle').textContent = v.sub;
  view.setAttribute('aria-busy', 'true');
  let html;
  try { html = await v.render(); }
  catch (e) { html = card('Could not load this page', '', `<p class="muted">${esc(e.message)}</p>`); }
  if (token !== routeToken) return;
  view.innerHTML = html;
  view.removeAttribute('aria-busy');
  v.after?.();
}

// ---------- actions (buttons) and forms --------------------------------
const actions = {
  refresh: () => route(),
  close: () => $('#dlg').close(),
  async allocate(b) { toast(requestSummary(await api(`/requests/${b.dataset.id}/allocate`, {}))); route(); },
  async receive(b) {
    const r = await api(`/transfers/${b.dataset.id}/receive`, {});
    toast(r.status === 'RECEIVED' ? 'Transfer received.' : 'The unit expired in transit, so the transfer was cancelled.', r.status !== 'RECEIVED');
    route();
  },
  async sweep() {
    const r = await api('/sweep', {});
    toast(`Sweep complete: ${r.marked_expired} marked expired, ${r.flagged_near_expiry} flagged near expiry.`);
    route();
  },
  donate(b) {
    dialog(`<h2>Record donation</h2><p class="muted">${esc(b.dataset.name)}</p>
      <form class="form" data-form="donation"><input type="hidden" name="donor_id" value="${esc(b.dataset.id)}">
      <label>Collected at<select name="hospital_id" required>${hospitalOptions('Choose…')}</select></label>
      <label>Volume (ml)<input name="volume_ml" type="number" min="200" max="500" value="350" required></label>
      <div class="row"><button type="button" class="btn ghost" data-act="close">Cancel</button><button class="btn">Record</button></div></form>`);
  },
  async unit(b) {
    const { unit: u, history, allocation } = await api('/units/' + b.dataset.id);
    const movable = ['AVAILABLE', 'NEAR_EXPIRY'].includes(u.status);
    const others = meta.hospitals.filter(h => h.hospital_id !== u.hospital_id);
    dialog(`<h2>Unit #${esc(u.unit_id)} · ${esc(u.group_name)}</h2><p>${pill(u.status)}</p>
      <dl><dt>Held at</dt><dd>${esc(u.hospital_name)}</dd><dt>Donor</dt><dd>${esc(u.donor_name)}</dd>
      <dt>Volume</dt><dd>${esc(u.volume_ml)} ml</dd><dt>Collected</dt><dd>${day(u.collection_date)}</dd>
      <dt>Expires</dt><dd>${day(u.expiry_date)} <span class="muted">(${esc(u.days_to_expiry)} days)</span></dd>
      ${allocation.map(a => `<dt>Issued to</dt><dd>${esc(a.patient_ref)} · request #${esc(a.request_id)}</dd>`).join('')}</dl>
      <ul class="trail">${history.map(h => `<li>${h.old_status ? esc(words(h.old_status)) + ' → ' : ''}${esc(words(h.new_status))}<time>${when(h.changed_at)}</time></li>`).join('')}</ul>
      <form class="form" data-form="move"><input type="hidden" name="unit_id" value="${esc(u.unit_id)}">
      ${movable ? `<label style="grid-column:1/-1">Move to another hospital<select name="to_hospital_id" required>${options(others, 'hospital_id', 'hospital_name', 'Choose destination…')}</select></label>` : ''}
      <div class="row"><button type="button" class="btn ghost" data-act="close">Close</button>${movable ? '<button class="btn">Start transfer</button>' : ''}</div></form>`);
  },
};

const forms = {
  async donor(d, f) { await api('/donors', d); toast(`${d.full_name} registered.`); f.reset(); route(); },
  async request(d) { d.allocate = d.allocate === 'on'; toast(requestSummary(await api('/requests', d))); route(); },
  async donation(d) { const r = await api('/donations', d); $('#dlg').close(); toast(`Donation recorded as unit #${r.unit_id}.`); route(); },
  async move(d) { await api('/transfers', d); $('#dlg').close(); toast(`Unit #${d.unit_id} is now in transit.`); route(); },
};

document.addEventListener('click', async e => {
  const b = e.target.closest('[data-act]');
  if (!b) return;
  try { await actions[b.dataset.act](b); } catch (err) { toast(err.message, true); }
});

document.addEventListener('submit', async e => {
  const handler = forms[e.target.dataset.form];
  if (!handler) return;
  e.preventDefault();
  const btn = e.target.querySelector('button:not([type=button])');
  if (btn) btn.disabled = true;
  try { await handler(Object.fromEntries(new FormData(e.target)), e.target); }
  catch (err) { toast(err.message, true); }
  finally { if (btn) btn.disabled = false; }
});

document.addEventListener('change', e => {
  const key = e.target.dataset.filter;
  if (key) { unitFilter[key] = e.target.value; route(); }
});

document.addEventListener('input', e => {
  const id = e.target.dataset.search;
  if (!id) return;
  const q = e.target.value.trim().toLowerCase();
  document.querySelectorAll(`#${id} tr`).forEach(tr => { tr.hidden = !tr.textContent.toLowerCase().includes(q); });
});

window.addEventListener('hashchange', () => { $('#dlg').close(); route(); });

(async () => {
  const conn = $('#conn');
  try {
    meta = await api('/meta');
    conn.textContent = `${meta.user} @ ${meta.dsn}`;
    conn.className = 'conn up';
  } catch (e) {
    conn.textContent = 'Not connected';
    conn.className = 'conn down';
  }
  route();
})();
