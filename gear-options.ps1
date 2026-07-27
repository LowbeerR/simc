# ============================================================================
#  SimC gear scanner — local "Top Gear" + crafted-stat optimizer
#
#  Reads a SimC addon export (clipboard by default, or -InputFile), generates
#  profilesets for:
#    * every bag item swapped into its slot
#    * every legal ring pair and trinket pair
#    * every legal weapon combination (validated against the item DB)
#    * every secondary-stat combination of each equipped crafted item
#    * every craftable Midnight armor piece for your armor type (Martyr's set
#      for cloth) plus crafted neck/ring/cloak, at -CraftedIlvl, all stat mixes
#    * every Great Vault choice (export while rewards are unclaimed!), both
#      as-dropped and fully upgraded on its track, ignoring crest costs
#    * Voidforge (Ascendant Voidcore) upgrades: vault/bag/equipped weapons and
#      trinkets on a maxed Hero/Myth track -> ilvl 298, max crafted -> +10
#  then runs one simulation and prints a ranked upgrade table.
#
#  Usage:  sim-gear.bat                       (uses clipboard)
#          sim-gear.bat my_characters\me.simc
#          gear-options.ps1 -TargetError 0.1 -FightStyle DungeonSlice
#          gear-options.ps1 -CraftedIlvl 0    (skip the crafted-candidate scan)
# ============================================================================
param(
    [string]$InputFile,
    [double]$TargetError = 0.3,   # FILTER-scan precision (ranks the field + table). Loose is fine:
                                  # winners are re-simmed precisely in the refine stage. 0.3~=35% faster than 0.2.
    [string]$FightStyle,
    [int]$CraftedIlvl = 285,
    [int]$MinIlvl = -1,      # ignore alternatives below this ilvl even when maxed; -1 = auto (lowest equipped), 0 = keep everything
    [int]$BeamWidth = 3,     # upgrade-path beam search: states kept per depth (1 = greedy)
    [int]$BeamVariants = 2,  # candidate stat/upgrade variants considered per slot (for stat diversification)
    [int]$MaxChanges = 4,    # deepest set the path explores (you rarely fund more at once)
    [switch]$NoBrowser,
    [switch]$DryRun          # generate the .simc and stop (don't simulate)
)

$ErrorActionPreference = 'Stop'
$simcRoot = $PSScriptRoot
$simcExe  = Join-Path $simcRoot 'build\simc.exe'
$itemDb   = Join-Path $simcRoot 'engine\dbc\generated\item_data.inc'
$outDir   = Join-Path $simcRoot 'my_characters'

if (-not (Test-Path $simcExe)) { throw "simc.exe not found at $simcExe - build it first (see README-LOCAL.md)" }
New-Item -ItemType Directory -Force $outDir | Out-Null

# ============================================================================
#  Interactive HTML report. Self-contained (embedded CSS/JS, no internet):
#  colored source badges, click-to-filter chips, sortable table, and the
#  measured cumulative upgrade-path panel with a "how many upgrades can I
#  afford" budget slider.
# ============================================================================
function New-GearReport {
    param($Path, $Meta, $Rows, $Priority)
    function ConvertTo-JsonArray($items) {
        if (-not $items -or @($items).Count -eq 0) { return '[]' }
        '[' + ((@($items) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join ',') + ']'
    }
    $tpl = @'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
:root{
  --bg:#14161c; --panel:#1c1f29; --panel2:#232734; --line:#30360033; --text:#e6e8ee;
  --muted:#9aa0ad; --gain:#39d98a; --loss:#ff6b6b; --accent:#7aa2ff;
  --craftable:#b07cff; --recraft:#3ec8c8; --crest:#ff9f43; --bag:#5aa9ff;
  --vault:#ffd24a; --voidforge:#ff5ed0; --weapon:#ff7062; --swap:#5fd35f;
  --combined:#c9ced8; --baseline:#ffd24a;
  --r-crest:#ff9f43; --r-spark:#7ad0ff; --r-voidcore:#ff5ed0; --r-gold:#ffd24a; --r-free:#6f7787;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 "Segoe UI",system-ui,sans-serif}
a{color:var(--accent)}
.wrap{max-width:1180px;margin:0 auto;padding:22px}
h1{font-size:22px;margin:0 0 2px}
.sub{color:var(--muted);font-size:13px;margin-bottom:18px}
.sub b{color:var(--text)}
.panel{background:var(--panel);border:1px solid #2a2f3b;border-radius:12px;padding:18px;margin-bottom:20px}
.panel h2{font-size:15px;margin:0 0 14px;letter-spacing:.3px;text-transform:uppercase;color:var(--muted)}
/* badges */
.badge{display:inline-block;padding:1px 8px;border-radius:999px;font-size:11px;font-weight:600;
  color:#11131a;white-space:nowrap}
.b-craftable{background:var(--craftable)} .b-recraft{background:var(--recraft)}
.b-crest{background:var(--crest)} .b-bag{background:var(--bag)} .b-vault{background:var(--vault)}
.b-voidforge{background:var(--voidforge)} .b-weapon{background:var(--weapon)} .b-swap{background:var(--swap)}
.b-combined{background:var(--combined)} .b-baseline{background:var(--baseline)}
/* cost pills */
.cost{display:inline-block;padding:1px 7px;border-radius:6px;font-size:11px;font-weight:600;
  border:1px solid #3a4150;white-space:nowrap}
.cost.k-crest{color:var(--r-crest);border-color:var(--r-crest)}
.cost.k-spark{color:var(--r-spark);border-color:var(--r-spark)}
.cost.k-voidcore{color:var(--r-voidcore);border-color:var(--r-voidcore)}
.cost.k-gold{color:var(--r-gold);border-color:var(--r-gold)}
.cost.k-free{color:var(--r-free);border-color:#3a4150}
/* priority */
.budget{display:flex;align-items:center;gap:14px;flex-wrap:wrap;margin-bottom:6px}
.budget input[type=range]{flex:1;min-width:180px;accent-color:var(--accent)}
.budget .read{font-size:13px;color:var(--muted)}
.budgets{display:flex;gap:16px;flex-wrap:wrap;margin-bottom:14px;align-items:center}
.budgets label{font-size:12px;color:var(--muted)}
.budgets input[type=number]{width:74px;background:var(--panel2);border:1px solid #3a4150;color:var(--text);
  border-radius:6px;padding:4px 7px;margin-left:5px}
.big{font-size:30px;font-weight:700;color:var(--gain)}
.big small{font-size:14px;color:var(--muted);font-weight:400}
.bcost{font-size:13px;margin:2px 0 10px}
.bcost.over{color:var(--loss)}
.bcost.ok{color:var(--muted)}
.step{display:grid;grid-template-columns:30px 1fr 130px 78px 78px;gap:10px;align-items:center;
  padding:8px 10px;border-radius:8px;margin-bottom:6px;background:var(--panel2);opacity:.42;
  transition:opacity .15s,outline .15s;border:1px solid transparent}
.step.on{opacity:1}
.step.edge{outline:2px solid var(--accent)}
.step.unaff{outline:1px dashed var(--loss)}
.step .n{width:26px;height:26px;border-radius:50%;background:#0d0f15;display:flex;align-items:center;
  justify-content:center;font-weight:700;color:var(--accent)}
.step .li{display:flex;align-items:center;gap:7px;margin:1px 0}
.step .nm{font-weight:600}
.step .slot{color:var(--muted);font-size:12px}
.step .marg,.step .cum{text-align:right;font-variant-numeric:tabular-nums}
.step .marg{color:var(--gain)} .step .cum{font-weight:700}
.note{color:var(--muted);font-size:12px;margin-top:6px}
/* filters */
.chips{display:flex;flex-wrap:wrap;gap:7px;margin-bottom:10px}
.chip{cursor:pointer;user-select:none;padding:3px 11px;border-radius:999px;font-size:12px;font-weight:600;
  border:1px solid #3a4150;color:var(--muted);background:transparent}
.chip.on{color:#11131a}
.chip.on.b-craftable{background:var(--craftable);border-color:var(--craftable)}
.chip.on.b-recraft{background:var(--recraft);border-color:var(--recraft)}
.chip.on.b-crest{background:var(--crest);border-color:var(--crest)}
.chip.on.b-bag{background:var(--bag);border-color:var(--bag)}
.chip.on.b-vault{background:var(--vault);border-color:var(--vault)}
.chip.on.b-voidforge{background:var(--voidforge);border-color:var(--voidforge)}
.chip.on.b-weapon{background:var(--weapon);border-color:var(--weapon)}
.chip.on.b-swap{background:var(--swap);border-color:var(--swap)}
.chip.slotchip.on{background:var(--accent);border-color:var(--accent)}
.bar2{display:flex;gap:10px;align-items:center;margin-bottom:12px;flex-wrap:wrap}
.bar2 input[type=search]{background:var(--panel2);border:1px solid #3a4150;color:var(--text);
  border-radius:8px;padding:6px 10px;min-width:200px}
.bar2 .cnt{color:var(--muted);font-size:12px}
/* table */
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
th,td{padding:7px 9px;text-align:left;border-bottom:1px solid #262b36}
th{color:var(--muted);font-size:12px;font-weight:600;cursor:pointer;white-space:nowrap}
th.num,td.num{text-align:right}
tr.row:hover{background:#20242f}
tr.base{background:#2a2410;outline:1px solid var(--baseline)}
.delta.pos{color:var(--gain)} .delta.neg{color:var(--loss)}
.dbar{position:relative;height:6px;border-radius:3px;background:#262b36;margin-top:4px;overflow:hidden}
.dbar i{position:absolute;top:0;bottom:0;left:50%;border-radius:3px}
.dbar i.pos{background:var(--gain)} .dbar i.neg{background:var(--loss)}
.dbar u{position:absolute;top:-2px;bottom:-2px;background:repeating-linear-gradient(90deg,rgba(230,232,238,.5) 0 1px,transparent 1px 3px)}
.err{color:var(--muted);font-size:10px;font-weight:400;white-space:nowrap}
.item{max-width:520px}
.muted{color:var(--muted)}
</style></head>
<body><div class="wrap">
  <h1>__TITLE__</h1>
  <div class="sub" id="sub"></div>

  <div class="panel">
    <h2>Upgrade priority &mdash; best measured set per budget</h2>
    <div class="budget">
      <span class="read">How many changes:</span>
      <input type="range" id="budget" min="0" max="0" value="0">
      <span class="read"><b id="bnum">0</b></span>
    </div>
    <div class="budgets">
      <span class="read">My resources &mdash;</span>
      <label>Crests<input type="number" id="bCrests" min="0" placeholder="&infin;"></label>
      <label>Sparks<input type="number" id="bSparks" min="0" placeholder="&infin;"></label>
      <label>Voidcores<input type="number" id="bVoid" min="0" placeholder="&infin;"></label>
      <span class="read" id="affNote"></span>
    </div>
    <div class="big" id="bdps">&mdash;</div>
    <div class="bcost ok" id="bcost"></div>
    <div id="steps"></div>
    <div class="note">Each row is the best <i>set</i> of that many changes, found by a beam search
      that tries several stat/upgrade combinations per slot and measures each &mdash; so it catches
      cases where two picks share a secondary stat and a lower-solo variant combines better. Sets are
      simmed whole, so the totals already account for stat diminishing returns. Winners and sets are
      refined at target_error <b id="te"></b> (Raidbots-style: the broad scan only filters, the
      shortlist is re-simmed precisely). The &plusmn; is the 1&sigma; Monte&nbsp;Carlo error (also the
      dashed whisker on each bar); if a deeper set's range overlaps a shallower one, the extra change
      isn't really buying anything.</div>
  </div>

  <div class="panel">
    <h2>All alternatives</h2>
    <div class="chips" id="srcchips"></div>
    <div class="chips" id="slotchips"></div>
    <div class="bar2">
      <input type="search" id="q" placeholder="filter by item name...">
      <label class="muted"><input type="checkbox" id="gainsonly"> gains only</label>
      <span class="cnt" id="cnt"></span>
    </div>
    <table id="tbl"><thead><tr>
      <th data-sort="src">Source</th>
      <th data-sort="slot">Slot</th>
      <th data-sort="item">Item</th>
      <th data-sort="cost">Cost</th>
      <th class="num" data-sort="dps">DPS</th>
      <th class="num" data-sort="delta">&Delta;%</th>
      <th class="num" data-sort="eff" title="DPS gain per 100 crests spent">&Delta;%/100cr</th>
    </tr></thead><tbody id="rows"></tbody></table>
  </div>
</div>
<script>
const META=__META__, ROWS=__ROWS__, PRIO=__PRIO__;
const SRC={
  craftable:{label:'Craftable',cost:'Gold + profession'},
  recraft:{label:'Recraft',cost:'Recraft (gold)'},
  crest:{label:'Crest upgrade',cost:'Crests'},
  bag:{label:'Bag',cost:'Free (owned)'},
  vault:{label:'Vault',cost:'Free (vault pick)'},
  voidforge:{label:'Voidforge',cost:'Voidcore'},
  weapon:{label:'Weapon',cost:'Owned / varies'},
  swap:{label:'Swap',cost:'Free (owned)'},
  combined:{label:'Combined',cost:'—'},
  baseline:{label:'Current gear',cost:'—'}
};
function classify(opt){let m;
  if(/CURRENT GEAR \(baseline\)/.test(opt))return{key:'baseline',slot:'',item:'Current gear'};
  if(m=opt.match(/^ALL BEST UPGRADES COMBINED:\s*(.*)$/))return{key:'combined',slot:'all',item:m[1]};
  if(m=opt.match(/^craft(\d+) (\w+): (.+)$/))return{key:'craftable',slot:m[2],item:m[3]};
  if(m=opt.match(/^craft (\w+): (.+)$/))return{key:'recraft',slot:m[1],item:m[2]};
  if(m=opt.match(/^upgrade (\w+): (.+)$/))return{key:'crest',slot:m[1],item:m[2]};
  if(m=opt.match(/^vault (\w+): (.+)$/))return{key:'vault',slot:m[1],item:m[2]};
  if(m=opt.match(/^voidforge (\w+): (.+)$/))return{key:'voidforge',slot:m[1],item:m[2]};
  if(m=opt.match(/^weapon: (.+)$/))return{key:'weapon',slot:'weapon',item:m[1]};
  if(m=opt.match(/^rings: (.+)$/))return{key:'swap',slot:'finger',item:m[1]};
  if(m=opt.match(/^trinkets: (.+)$/))return{key:'swap',slot:'trinket',item:m[1]};
  if(m=opt.match(/^([a-z_0-9]+): (.+)$/))return{key:'bag',slot:m[1],item:m[2]};
  return{key:'bag',slot:'',item:opt};}
const slotGroup=s=>(s||'').replace(/[12]$/,'');
const fmt=n=>n.toLocaleString('en-US');
const pct=n=>(n>0?'+':'')+n.toFixed(2)+'%';
/* ---- resource costs ---- */
const costKind=c=>!c?'free':c.voidcores?'voidcore':c.sparks?'spark':c.crests?'crest':c.gold?'gold':'free';
function costLabel(c){if(!c)return'Free';const p=[];
  if(c.crests)p.push(c.crests+' '+(c.tier?c.tier+' ':'')+'crest'+(c.crests>1?'s':''));
  if(c.sparks)p.push(c.sparks+' Spark'+(c.sparks>1?'s':''));
  if(c.voidcores)p.push(c.voidcores+' Voidcore'+(c.voidcores>1?'s':''));
  if(p.length)return p.join(' + ');
  return c.gold?'Gold':'Free';}
function costPill(c){return `<span class="cost k-${costKind(c)}">${costLabel(c)}</span>`;}
const num=v=>{const n=parseInt(v,10);return isNaN(n)?Infinity:n;};

document.getElementById('sub').innerHTML=
  `<b>${META.Name}</b> &middot; ${META.Class} ${META.Spec} &middot; ${META.Fight} `+
  `&middot; target_error ${META.TargetErr} &middot; baseline <b>${fmt(Math.round(META.BaseDps))}</b> DPS `+
  `&middot; ${META.Stamp}`;
document.getElementById('te').textContent=META.RefineErr+'%';

/* ---- priority panel (beam search: best measured set of N changes) ---- */
const steps=PRIO.map(p=>({...p, parts:(p.items||[]).map(o=>{const c=classify(o);return{...c,src:SRC[c.key]};})}));
// each step is a COMPLETE set, so its cost is the set's resource total (not a running sum)
function setCost(b){const s=steps.find(x=>x.step===b); const c=s?s.cost:null;
  const t={sparks:0,voidcores:0,gold:false,crests:0,byTier:{}};
  if(c){t.sparks=c.sparks||0; t.voidcores=c.voidcores||0; t.gold=!!c.gold;
    if(c.crests){t.crests=c.crests; t.byTier[c.tier||'crest']=c.crests;}}
  return t;}
function cumCostLabel(t){const p=[];
  const tiers=Object.keys(t.byTier); if(tiers.length===1)p.push(t.crests+' '+tiers[0]+' crests');
  else if(t.crests)p.push(t.crests+' crests');
  if(t.sparks)p.push(t.sparks+' Sparks'); if(t.voidcores)p.push(t.voidcores+' Voidcores');
  if(t.gold&&!p.length)p.push('some gold'); return p.length?p.join(', '):'nothing (all free)';}
const stepBox=document.getElementById('steps');
stepBox.innerHTML=steps.map(s=>`
  <div class="step" data-step="${s.step}">
    <div class="n">${s.step}</div>
    <div>${s.parts.map(pt=>`<div class="li"><span class="badge b-${pt.key}">${pt.src.label}</span> <span class="nm">${pt.item}</span> <span class="slot">${slotGroup(pt.slot)}</span></div>`).join('')}</div>
    <div>${costPill(s.cost)}</div>
    <div class="marg">${pct(s.margPct)}</div>
    <div class="cum">${pct(s.cumPct)}<div class="err">&plusmn;${(s.err||0).toFixed(2)}</div></div>
  </div>`).join('')||'<div class="muted">No upgrades cleared the noise floor this run.</div>';
const slider=document.getElementById('budget');
let bestB=0,bestV=-1e9; steps.forEach(s=>{if(s.cumPct>bestV){bestV=s.cumPct;bestB=s.step;}});
slider.max=steps.length; slider.value=bestB;
const budCrests=document.getElementById('bCrests'), budSparks=document.getElementById('bSparks'), budVoid=document.getElementById('bVoid');
// largest N whose best-set cost fits the budget (each set is self-contained)
function affordableMax(){const cr=num(budCrests.value),sp=num(budSparks.value),vc=num(budVoid.value);
  let max=0; for(let b=1;b<=steps.length;b++){const t=setCost(b);
    if(t.crests<=cr&&t.sparks<=sp&&t.voidcores<=vc)max=b;} return max;}
function renderBudget(){const b=+slider.value;
  document.getElementById('bnum').textContent=(b===1?'1 change':b+' changes');
  const cur=steps.find(s=>s.step===b);
  const bd=document.getElementById('bdps');
  if(!cur){bd.innerHTML=`${fmt(Math.round(META.BaseDps))} DPS <small>(current gear)</small>`;}
  else{bd.innerHTML=`${fmt(cur.cumDps)} DPS <small>${pct(cur.cumPct)} vs current</small>`;}
  const t=setCost(b), cr=num(budCrests.value),sp=num(budSparks.value),vc=num(budVoid.value);
  const over=t.crests>cr||t.sparks>sp||t.voidcores>vc;
  const bc=document.getElementById('bcost');
  bc.className='bcost '+(over?'over':'ok');
  bc.innerHTML=b?`Costs: <b>${cumCostLabel(t)}</b>${over?' &mdash; over your budget':''}`:'';
  const aff=affordableMax();
  document.getElementById('affNote').innerHTML=(cr===Infinity&&sp===Infinity&&vc===Infinity)
    ?'' : `&rarr; best you can afford: <b>${aff} change${aff===1?'':'s'}</b> (${aff?pct(steps.find(s=>s.step===aff).cumPct):'current gear'})`;
  document.querySelectorAll('.step').forEach(el=>{const n=+el.dataset.step;
    el.classList.toggle('on',n<=b); el.classList.toggle('edge',n===b);
    el.classList.toggle('unaff',n===b&&over);});}
slider.addEventListener('input',renderBudget);
[budCrests,budSparks,budVoid].forEach(el=>el.addEventListener('input',()=>{slider.value=affordableMax();renderBudget();}));
renderBudget();

/* ---- table ---- */
const data=ROWS.map(r=>{const c=classify(r.opt);const co=r.cost||{};
  const weight=(co.voidcores||0)*1e6+(co.sparks||0)*1e4+(co.crests||0)+(co.gold?0.5:0);
  const eff=(co.crests>0&&r.delta>0)?r.delta/co.crests*100:null;
  return{...r,...c,sg:slotGroup(c.slot),src:SRC[c.key],weight,eff};});
const srcKeys=[...new Set(data.filter(d=>d.key!=='baseline'&&d.key!=='combined').map(d=>d.key))];
const slots=[...new Set(data.map(d=>d.sg).filter(Boolean))].sort();
const offSrc=new Set(), offSlot=new Set();
const maxAbs=Math.max(1,...data.map(d=>Math.abs(d.delta)));
function chip(id,label,cls){return `<span class="chip ${cls} on" data-${id}>${label}</span>`;}
document.getElementById('srcchips').innerHTML=
  srcKeys.map(k=>chip('src="'+k+'"',SRC[k].label,'b-'+k)).join('');
document.getElementById('slotchips').innerHTML=
  slots.map(s=>`<span class="chip slotchip on" data-slot="${s}">${s}</span>`).join('');
let sortKey='dps',sortDir=-1;
function draw(){
  const q=document.getElementById('q').value.toLowerCase();
  const go=document.getElementById('gainsonly').checked;
  let rows=data.filter(d=>{
    if(d.key==='baseline')return true;
    if(offSrc.has(d.key))return false;
    if(d.sg&&offSlot.has(d.sg))return false;
    if(go&&d.delta<=0)return false;
    if(q&&!d.item.toLowerCase().includes(q))return false;
    return true;});
  rows.sort((a,b)=>{let x,y;
    if(sortKey==='src'){return sortDir*a.src.label.localeCompare(b.src.label);}
    if(sortKey==='item'||sortKey==='slot'){return sortDir*String(a[sortKey]||'').localeCompare(String(b[sortKey]||''));}
    if(sortKey==='cost'){x=a.weight;y=b.weight;}
    else if(sortKey==='eff'){x=a.eff==null?-Infinity:a.eff;y=b.eff==null?-Infinity:b.eff;}
    else{x=a[sortKey];y=b[sortKey];}
    return sortDir*((x||0)-(y||0));});
  const scale=50/maxAbs;
  document.getElementById('rows').innerHTML=rows.map(d=>{
    const w=Math.abs(d.delta)*scale, side=d.delta>=0?'pos':'neg';
    const tip=d.delta*scale, e=(d.err||0)*scale;       // 1-sigma error whisker around the bar tip
    let l=50+tip-e, ww=2*e; if(l<0){ww+=l;l=0;} if(l+ww>100)ww=100-l;
    const whisk=(d.key==='baseline'||!e)?'':`<u style="left:${l}%;width:${Math.max(ww,0)}%"></u>`;
    const bar=d.key==='baseline'?'':`<div class="dbar"><i class="${side}" style="${d.delta>=0?'left:50%':'right:50%'};width:${w}%"></i>${whisk}</div>`;
    const costc=d.key==='baseline'?'':costPill(d.cost);
    const deltac=d.key==='baseline'?'—':`${pct(d.delta)} <span class="err">&plusmn;${(d.err||0).toFixed(2)}</span>`;
    return `<tr class="row ${d.key==='baseline'?'base':''}">
      <td><span class="badge b-${d.key}">${d.src.label}</span></td>
      <td class="muted">${d.sg||'—'}</td>
      <td class="item">${d.item}${bar}</td>
      <td>${costc}</td>
      <td class="num">${fmt(d.dps)}</td>
      <td class="num delta ${d.delta>0?'pos':d.delta<0?'neg':''}">${deltac}</td>
      <td class="num muted">${d.eff!=null?d.eff.toFixed(2):'—'}</td>
    </tr>`;}).join('');
  document.getElementById('cnt').textContent=rows.length+' shown';
}
document.querySelectorAll('#srcchips .chip').forEach(c=>c.onclick=()=>{
  const k=c.dataset.src; c.classList.toggle('on'); if(offSrc.has(k))offSrc.delete(k);else offSrc.add(k); draw();});
document.querySelectorAll('#slotchips .chip').forEach(c=>c.onclick=()=>{
  const k=c.dataset.slot; c.classList.toggle('on'); if(offSlot.has(k))offSlot.delete(k);else offSlot.add(k); draw();});
document.getElementById('q').oninput=draw;
document.getElementById('gainsonly').onchange=draw;
document.querySelectorAll('th[data-sort]').forEach(th=>th.onclick=()=>{
  const k=th.dataset.sort; if(sortKey===k)sortDir*=-1;else{sortKey=k;sortDir=(k==='dps'||k==='delta')?-1:1;} draw();});
draw();
</script></body></html>
'@
    $title = "Gear Scan &mdash; $($Meta.Name)"
    $html = $tpl.Replace('__TITLE__', $title).
                 Replace('__META__', ($Meta | ConvertTo-Json -Compress)).
                 Replace('__ROWS__', (ConvertTo-JsonArray $Rows)).
                 Replace('__PRIO__', (ConvertTo-JsonArray $Priority))
    Set-Content -Path $Path -Value $html -Encoding UTF8
}

# ---------------------------------------------------------------- input ----
if ($InputFile) {
    $text = Get-Content $InputFile -Raw
    Write-Host "Input: $InputFile"
} else {
    $text = Get-Clipboard -Raw
    Write-Host "Input: clipboard"
}

# simc writes the two-word classes WITHOUT an underscore ("demonhunter=Name",
# "deathknight=Name") in both the addon export and its own profiles, so accept
# those spellings and normalise to the underscored keys the tables below use.
$classNames = 'death_knight','demon_hunter','deathknight','demonhunter','druid','evoker','hunter','mage','monk','paladin','priest','rogue','shaman','warlock','warrior'
$classAlias = @{ deathknight = 'death_knight'; demonhunter = 'demon_hunter' }
$classRe = "^($($classNames -join '|'))=`"?([^`"]+)`"?\s*$"
$charClass = $null; $charName = $null
foreach ($l in ($text -split "`r?`n")) {
    if ($l -match $classRe) { $charClass = $Matches[1]; $charName = $Matches[2]; break }
}
if ($charClass -and $classAlias[$charClass]) { $charClass = $classAlias[$charClass] }
if (-not $charClass) { throw "Input does not look like a SimC addon export (no 'class=`"Name`"' line found). Copy the /simc text in-game first." }
$charSpec = if ($text -match '(?m)^spec=(\w+)\s*$') { $Matches[1] } else { '?' }
Write-Host "Character: $charName ($charClass, $charSpec)"

# SimC has no support at all for these healer specs (they fail with
# "No active players in sim") - fail early with a useful message instead
$unsimmable = @{ priest = 'discipline', 'holy'; paladin = @('holy'); monk = @('mistweaver') }
if ($unsimmable[$charClass] -and $charSpec -in $unsimmable[$charClass]) {
    throw "SimC cannot simulate healer specs - there is no $charSpec $charClass module. Log into a damage spec (e.g. shadow for priest), equip its loadout, and run /simc again."
}

# ---------------------------------------------------------------- parse ----
$slotRe = '^(?<slot>head|neck|shoulder|back|chest|wrist|hands|waist|legs|feet|finger1|finger2|trinket1|trinket2|main_hand|off_hand)=(?<spec>,.+)$'
$nameRe = '^#\s+(?<name>.+?)\s+\((?<ilvl>\d+)\)\s*$'

$equipped = @{}                                   # slot -> @{Name; Spec; Id}
$bags     = [System.Collections.Generic.List[object]]::new()
$vault    = [System.Collections.Generic.List[object]]::new()
$section = 'equipped'; $pendingName = '?'; $pendingIlvl = 0
foreach ($l in ($text -split "`r?`n")) {
    if ($l -match '^###\s*Gear from Bags')        { $section = 'bags';     continue }
    if ($l -match '^###\s*Weekly Reward Choices') { $section = 'vault';    continue }
    if ($l -match '^###\s*End of Weekly Reward')  { $section = 'equipped'; continue }
    if ($l -match '^###\s*Additional')            { $section = 'done';     continue }
    if ($section -eq 'done') { continue }
    if ($l -match $nameRe) { $pendingName = "$($Matches.name) ($($Matches.ilvl))"; $pendingIlvl = [int]$Matches.ilvl; continue }
    $candidate = if ($section -ne 'equipped' -and $l -match '^#\s*(.+)$') { $Matches[1] } else { $l }
    if ($candidate -match $slotRe) {
        $slot = $Matches.slot; $spec = $Matches.spec
        $id = if ($spec -match 'id=(\d+)') { [int]$Matches[1] } else { 0 }
        # pscustomobject (not hashtable): Group-Object/Where-Object property
        # binding on hashtables silently fails under Windows PowerShell 5.1
        $item = [pscustomobject]@{ Slot = $slot; Spec = $spec; Name = $pendingName; Id = $id; Ilvl = $pendingIlvl }
        switch ($section) {
            'bags'  { $bags.Add($item) }
            'vault' { $vault.Add($item) }
            default { $equipped[$item.Slot] = $item }
        }
        $pendingName = '?'; $pendingIlvl = 0
    }
}
Write-Host "Equipped items: $($equipped.Count), bag items: $($bags.Count), vault items: $($vault.Count)"
if ($vault.Count -eq 0) {
    Write-Host 'Note: no Great Vault section in the export. The addon adds it only while you' -ForegroundColor DarkYellow
    Write-Host '      have UNCLAIMED weekly rewards - run /simc before opening the vault.' -ForegroundColor DarkYellow
}

# ------------------------------------------------------- item DB lookup ----
# Validates weapon legality; SimC itself happily sims combos you cannot equip
# in game (2H + off-hand, other classes' weapons), so we must filter here.
$classMaskBit = @{ warrior=0x1; paladin=0x2; hunter=0x4; rogue=0x8; priest=0x10; death_knight=0x20; shaman=0x40; mage=0x80; warlock=0x100; monk=0x200; druid=0x400; demon_hunter=0x800; evoker=0x1000 }
# usable weapon subclasses per class (0 axe1h,1 axe2h,2 bow,3 gun,4 mace1h,5 mace2h,
# 6 polearm,7 sword1h,8 sword2h,9 warglaive,10 staff,13 fist,15 dagger,18 xbow,19 wand)
$weaponProf = @{
    death_knight = 0,1,4,5,6,7,8
    demon_hunter = 0,7,9,13,15
    druid        = 4,5,6,10,13,15
    evoker       = 0,1,4,5,7,8,10,13,15
    hunter       = 0,1,2,3,6,7,8,10,13,15,18
    mage         = 7,10,15,19
    monk         = 0,4,6,7,10,13
    paladin      = 0,1,4,5,6,7,8
    priest       = 4,10,15,19
    rogue        = 0,4,7,13,15
    shaman       = 0,1,4,5,10,13,15
    warlock      = 7,10,15,19
    warrior      = 0,1,2,3,4,5,6,7,8,10,13,15,18
}

$weaponIds = @($equipped['main_hand'], $equipped['off_hand']) + @($bags) + @($vault) |
             Where-Object { $_ -and $_.Slot -in 'main_hand','off_hand' } | ForEach-Object { $_.Id } | Sort-Object -Unique
$itemInfo = @{}
if ($weaponIds.Count -gt 0) {
    $idAlt = ($weaponIds -join '|')
    Select-String -Path $itemDb -Pattern "^\s*\{\s*`".*`",\s*($idAlt)," | ForEach-Object {
        if ($_.Line -match '^\s*\{\s*"(?<n>.*)",\s*(?<id>\d+),\s*(?<rest>.*)$') {
            $f = ($Matches.rest -split ',').ForEach({ $_.Trim() })
            $cm = $f[17]
            $mask = if ($cm -like '0x*') { [Convert]::ToUInt64($cm.Substring(2), 16) } else { [uint64]$cm }
            $itemInfo[[int]$Matches.id] = @{
                InvType   = [int]$f[8]    # 13 1H, 14 shield, 15 bow, 17 2H, 21 MH, 22 OH, 23 holdable, 26 wand/gun/xbow
                ItemClass = [int]$f[9]
                SubClass  = [int]$f[10]
                ClassMask = $mask
            }
        }
    }
}

function Test-Usable($item) {
    $i = $itemInfo[$item.Id]
    if (-not $i) { return $true }                       # unknown -> let it through
    $bit = $classMaskBit[$charClass]
    if (($i.ClassMask -band 0xFFFFFFFFL) -ne 0xFFFFFFFFL -and -not ($i.ClassMask -band $bit)) { return $false }
    if ($i.ItemClass -eq 2 -and $weaponProf[$charClass] -and $i.SubClass -notin $weaponProf[$charClass]) { return $false }
    return $true
}
function Test-TwoHand($item) {
    $i = $itemInfo[$item.Id]
    if (-not $i) { return $false }
    if ($i.InvType -in 15,17) { return $true }                          # bow, 2H
    if ($i.InvType -eq 26 -and $i.SubClass -in 3,18) { return $true }   # gun, crossbow
    return $false
}

# ----------------------------------------------- upgrade-track bonus data ----
# Upgrade-rank bonus ids carry a type-34 entry (track group) and a type-49
# entry (scaling config). Midnight tracks have 6 usable ranks; data rows 7-8
# exist but are unreachable in game. "Max upgrade" = swap the item's rank
# bonus id for rank 6 of the same group; simc computes the resulting ilvl.
# Voidforge: bonus 13654 = Ascendant Voidforged (absolute ilvl 298, only on
# fully upgraded Hero/Myth weapons & trinkets); 13655 = crafted version (+10).
$trackGroup = @{}; $trackCfg = @{}
foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $simcRoot 'engine\dbc\generated\item_bonus.inc'))) {
    if ($l -match '^\s*\{\s*\d+,\s*(\d+),\s*(34|49),\s*(\d+),') {
        $bid = [int]$Matches[1]
        if ($Matches[2] -eq '34') { $trackGroup[$bid] = [int]$Matches[3] } else { $trackCfg[$bid] = [int]$Matches[3] }
    }
}
$rank6 = @{}                                       # track group -> rank-6 bonus id
foreach ($g in ($trackGroup.Values | Sort-Object -Unique)) {
    $members = @($trackGroup.Keys | Where-Object { $trackGroup[$_] -eq $g -and $trackCfg.ContainsKey($_) } |
                 Sort-Object { $trackCfg[$_] })
    if ($members.Count -ge 6) { $rank6[$g] = $members[5] }
}
$eliteGroups = @($rank6.Keys | Sort-Object { $trackCfg[$rank6[$_]] } | Select-Object -Last 2)   # Hero + Myth

# ------------------------------------------------------- resource cost model ----
# Midnight S1 economy (edit if the game changes; verified via Wowhead / Blizzard
# Watch, 2026-06): every upgrade RANK costs 20 Dawncrests of the track's tier
# (5 ranks = 100 to fully upgrade a track; ~100 crest weekly cap = 5 upgrades).
# Crafted gear costs 80 MYTH crests + Sparks of Radiance (2 per item, 4 for 2H;
# one Spark/week - usually the real bottleneck). Valorstones gone (small gold).
# Recrafting only changes stats: gold, no Spark. Voidforging costs voidcores.
$costModel = @{
    CrestPerRank  = 20
    CraftCrests   = 80
    CraftSparks   = 2
    CraftSparks2H = 4
    Voidcore      = 1      # voidcores per Ascendant Voidforge
}
# Name the 5 gear tracks by ascending max ilvl (robust to id changes); crests of
# different tiers are different currencies, so each upgrade carries ONE tier.
$trackTierNames = 'Adventurer','Veteran','Champion','Hero','Myth'
$groupMembers = @{}; $groupTier = @{}
foreach ($g in $rank6.Keys) {
    $groupMembers[$g] = @($trackGroup.Keys | Where-Object { $trackGroup[$_] -eq $g -and $trackCfg.ContainsKey($_) } |
                          Sort-Object { $trackCfg[$_] })
}
$gearGroupsAsc = @($rank6.Keys | Sort-Object { $trackCfg[$rank6[$_]] } | Select-Object -Last 5)
for ($i = 0; $i -lt $gearGroupsAsc.Count; $i++) {
    $groupTier[$gearGroupsAsc[$i]] = $trackTierNames[$trackTierNames.Count - $gearGroupsAsc.Count + $i]
}

function New-Cost { @{ crests = 0; tier = $null; sparks = 0; voidcores = 0; gold = $false } }
function Get-TrackStepInfo([string]$spec) {         # @{Tier; Steps} from current rank to rank 6, else $null
    $tid = Get-TrackId $spec
    if (-not $tid) { return $null }
    $g = $trackGroup[$tid]; $max = $rank6[$g]
    if (-not $max -or -not $groupMembers[$g]) { return $null }
    $curIdx = [array]::IndexOf($groupMembers[$g], $tid)
    $maxIdx = [array]::IndexOf($groupMembers[$g], $max)
    if ($curIdx -lt 0 -or $maxIdx -lt 0) { return $null }
    return @{ Tier = $groupTier[$g]; Steps = [math]::Max(0, $maxIdx - $curIdx) }
}
function Add-StepCrests($cost, [string]$specBeforeMax) {   # cost of upgrading this item to rank 6
    $info = Get-TrackStepInfo $specBeforeMax
    if (-not $info -or $info.Steps -le 0) { return }
    $cost.crests += $info.Steps * $costModel.CrestPerRank
    if (-not $cost.tier) { $cost.tier = $info.Tier } elseif ($cost.tier -ne $info.Tier) { $cost.tier = 'mixed' }
}
function Merge-Cost($a, $b) {                        # accumulate $b into $a
    $a.crests += $b.crests; $a.sparks += $b.sparks; $a.voidcores += $b.voidcores
    if ($b.gold) { $a.gold = $true }
    if ($b.tier) { if (-not $a.tier) { $a.tier = $b.tier } elseif ($a.tier -ne $b.tier) { $a.tier = 'mixed' } }
    return $a
}

function Get-TrackId([string]$spec) {
    if ($spec -notmatch 'bonus_id=([\d/]+)') { return 0 }
    foreach ($b in ($Matches[1] -split '/')) {
        $bid = [int]$b
        if ($trackGroup.ContainsKey($bid) -and $trackCfg.ContainsKey($bid)) { return $bid }
    }
    return 0
}
function Set-MaxTrack([string]$spec) {             # $null if not upgradable further
    $tid = Get-TrackId $spec
    if (-not $tid) { return $null }
    $max = $rank6[$trackGroup[$tid]]
    if (-not $max -or $trackCfg[$tid] -ge $trackCfg[$max]) { return $null }
    $null = $spec -match 'bonus_id=([\d/]+)'
    $ids = ($Matches[1] -split '/') | ForEach-Object { if ([int]$_ -eq $tid) { $max } else { $_ } }
    return $spec -replace 'bonus_id=[\d/]+', "bonus_id=$($ids -join '/')"
}
function Add-Voidforge([string]$spec) {            # $null if ineligible / already forged
    if ($spec -match 'bonus_id=[\d/]*\b(13654|13655)\b') { return $null }
    if ($spec -match 'crafting_quality=(\d+)') {
        if ([int]$Matches[1] -lt 5) { return $null }
        if ($spec -match 'bonus_id=') { return $spec -replace 'bonus_id=([\d/]+)', 'bonus_id=$1/13655' }
        return "$spec,bonus_id=13655"
    }
    $tid = Get-TrackId $spec
    if (-not $tid -or $trackGroup[$tid] -notin $eliteGroups) { return $null }
    $s = Set-MaxTrack $spec; if (-not $s) { $s = $spec }    # must be fully upgraded first
    return $s -replace 'bonus_id=([\d/]+)', 'bonus_id=$1/13654'
}
function Test-OtherSlotHasItem([string]$slot, [int]$id) {   # unique-equipped guard for paired slots
    $other = switch ($slot) {
        'finger1'  { 'finger2' }  'finger2'  { 'finger1' }
        'trinket1' { 'trinket2' } 'trinket2' { 'trinket1' }
        default    { $null }
    }
    return [bool]($other -and $equipped[$other] -and $equipped[$other].Id -eq $id)
}
function Get-MaxedIlvl([string]$spec) {            # estimated ilvl at max track rank, 0 if no track
    $tid = Get-TrackId $spec
    if (-not $tid) { return 0 }
    $max = $rank6[$trackGroup[$tid]]
    if (-not $max) { return 0 }
    # empirical Midnight S1 mapping: scaling config 224 = ilvl 276, ~3.25 ilvl/step
    return [int][math]::Floor(276 + ($trackCfg[$max] - 224) * 3.25)
}
function Get-BestVersion($item) {                  # item fully upgraded on its track (or as-is)
    $m = Set-MaxTrack $item.Spec
    if (-not $m) { return $item }
    $est = Get-MaxedIlvl $item.Spec
    [pscustomobject]@{ Slot = $item.Slot; Spec = $m; Name = "$($item.Name) MAXED($est)"; Id = $item.Id; Ilvl = $est }
}

# Ignore alternatives that stay below the equipped ilvl floor even when fully
# upgraded - junk in bags just slows the sim down. -MinIlvl 0 keeps everything
# (do that when a low-ilvl trinket effect might still be competitive).
if ($MinIlvl -lt 0) {
    $MinIlvl = ($equipped.Values | ForEach-Object Ilvl | Where-Object { $_ -gt 0 } | Measure-Object -Minimum).Minimum
    if (-not $MinIlvl) { $MinIlvl = 0 }
}
if ($MinIlvl -gt 0) { Write-Host "Ignoring alternatives below ilvl $MinIlvl even when maxed (-MinIlvl 0 to include everything)." }

# --------------------------------------------------- generate profilesets ---
$gen = [System.Collections.Generic.List[string]]::new()
$psMeta = @{}                                     # profileset name -> overrides (for the combined pass)
$psCost = @{}                                     # profileset name -> resource cost hashtable
$count = 0
function Add-ProfileSet([string]$name, [string[]]$overrides, $cost) {
    $clean = ($name -replace '[",]', '') -replace '\s+', ' '
    foreach ($ov in $overrides) { $script:gen.Add("profileset.`"$clean`"+=$ov") }
    $script:psMeta[$clean] = $overrides
    $script:psCost[$clean] = if ($cost) { $cost } else { New-Cost }   # empty = free (already owned)
    $script:count++
}

# 1) straight swaps for single-item slots: as-is and fully track-upgraded
foreach ($b in $bags | Where-Object { $_.Slot -in 'head','neck','shoulder','back','chest','wrist','hands','waist','legs','feet' }) {
    if ($b.Ilvl -ge $MinIlvl) { Add-ProfileSet "$($b.Slot): $($b.Name)" @("$($b.Slot)=$($b.Spec)") }   # owned: free
    $bb = Get-BestVersion $b
    if ($bb -ne $b -and $bb.Ilvl -ge $MinIlvl) {
        $c = New-Cost; Add-StepCrests $c $b.Spec     # cost to upgrade the bag item to max
        Add-ProfileSet "$($b.Slot): $($bb.Name)" @("$($b.Slot)=$($bb.Spec)") $c
    }
}

# 1b) crest upgrades for what you are wearing now
foreach ($slot in @($equipped.Keys | Sort-Object)) {
    $eb = Get-BestVersion $equipped[$slot]
    if ($eb -ne $equipped[$slot]) {
        $c = New-Cost; Add-StepCrests $c $equipped[$slot].Spec
        Add-ProfileSet "upgrade $($slot): $($eb.Name)" @("$slot=$($eb.Spec)") $c
    }
}

# 2) all ring pairs / trinket pairs (equipped + bags). Pool entries carry the
#    cost of getting that item to the shown rank (equipped/bag as-is = free,
#    bag MAXED = crests); a pair's cost is the sum of its two picks.
function Add-PairSets([string]$label, [string]$slot1, [string]$slot2) {
    $pool = @()
    foreach ($s in $slot1, $slot2) { if ($equipped[$s]) { $pool += [pscustomobject]@{ It = $equipped[$s]; Cost = (New-Cost) } } }
    foreach ($bi in ($bags | Where-Object { $_.Slot -in $slot1, $slot2 })) {
        $bv = Get-BestVersion $bi
        if ($bv.Ilvl -lt $MinIlvl) { continue }
        $c = New-Cost; if ($bv -ne $bi) { Add-StepCrests $c $bi.Spec }
        $pool += [pscustomobject]@{ It = $bv; Cost = $c }
    }
    $pool = $pool | Group-Object { $_.It.Id } | ForEach-Object { $_.Group[0] }     # unique-equipped
    $curIds = @($equipped[$slot1].Id, $equipped[$slot2].Id) | Sort-Object
    for ($i = 0; $i -lt $pool.Count; $i++) {
        for ($j = $i + 1; $j -lt $pool.Count; $j++) {
            $ids = @($pool[$i].It.Id, $pool[$j].It.Id) | Sort-Object
            if ("$ids" -eq "$curIds") { continue }                       # baseline
            $c = Merge-Cost (Merge-Cost (New-Cost) $pool[$i].Cost) $pool[$j].Cost
            Add-ProfileSet "$($label): $($pool[$i].It.Name) + $($pool[$j].It.Name)" @(
                "$slot1=$($pool[$i].It.Spec)", "$slot2=$($pool[$j].It.Spec)") $c
        }
    }
}
Add-PairSets 'rings'    'finger1'  'finger2'
Add-PairSets 'trinkets' 'trinket1' 'trinket2'

# 3) weapon combos, legality-checked. Pool entries carry upgrade cost like rings.
function New-WeaponPool([string]$slot) {
    $p = @(); if ($equipped[$slot]) { $p += [pscustomobject]@{ It = $equipped[$slot]; Cost = (New-Cost) } }
    foreach ($bi in ($bags | Where-Object Slot -eq $slot)) {
        $bv = Get-BestVersion $bi
        if ($bv.Ilvl -lt $MinIlvl) { continue }
        $c = New-Cost; if ($bv -ne $bi) { Add-StepCrests $c $bi.Spec }
        $p += [pscustomobject]@{ It = $bv; Cost = $c }
    }
    @($p | Where-Object { Test-Usable $_.It } | Group-Object { $_.It.Id } | ForEach-Object { $_.Group[0] })
}
$mhPool = New-WeaponPool 'main_hand'
$ohPool = New-WeaponPool 'off_hand'
$curMh = $equipped['main_hand'].Id; $curOh = if ($equipped['off_hand']) { $equipped['off_hand'].Id } else { 0 }

foreach ($mh in $mhPool) {
    if (Test-TwoHand $mh.It) {
        if ($mh.It.Id -eq $curMh -and $curOh -eq 0) { continue }
        $ov = @("main_hand=$($mh.It.Spec)")
        if ($curOh -ne 0) { $ov += 'off_hand=' }                          # clear equipped OH
        Add-ProfileSet "weapon: $($mh.It.Name)" $ov $mh.Cost
    } else {
        foreach ($oh in $ohPool) {
            if ($mh.It.Id -eq $curMh -and $oh.It.Id -eq $curOh) { continue }
            $c = Merge-Cost (Merge-Cost (New-Cost) $mh.Cost) $oh.Cost
            Add-ProfileSet "weapon: $($mh.It.Name) + $($oh.It.Name)" @(
                "main_hand=$($mh.It.Spec)", "off_hand=$($oh.It.Spec)") $c
        }
        if ($ohPool.Count -eq 0 -and $mh.It.Id -ne $curMh) {
            Add-ProfileSet "weapon: $($mh.It.Name)" @("main_hand=$($mh.It.Spec)") $mh.Cost
        }
    }
}

# 4) crafted gear: every secondary-stat combination
$statName = @{ 32 = 'Crit'; 36 = 'Haste'; 40 = 'Vers'; 49 = 'Mastery' }
$statPairs = @(@(32,36), @(32,40), @(32,49), @(36,40), @(36,49), @(40,49))
foreach ($slot in ($equipped.Keys | Sort-Object)) {
    $e = $equipped[$slot]
    if ($e.Spec -notmatch 'crafted_stats=(\d+)/(\d+)') { continue }
    $cur = @([int]$Matches[1], [int]$Matches[2]) | Sort-Object
    foreach ($p in $statPairs) {
        if ("$p" -eq "$cur") { continue }
        $newSpec = $e.Spec -replace 'crafted_stats=\d+/\d+', "crafted_stats=$($p[0])/$($p[1])"
        $c = New-Cost; $c.gold = $true       # recrafting only changes stats: gold, no Spark
        Add-ProfileSet "craft $($slot): $($e.Name) $($statName[$p[0]])/$($statName[$p[1]])" @("$slot=$newSpec") $c
    }
}

# 5) craftable candidates: every current-tier crafted armor piece for this
#    class's armor type, plus crafted neck/ring/cloak, simmed at -CraftedIlvl
#    with every secondary-stat mix. Crafted items are identified in the DB by
#    flags2 bit 0x4000 + epic quality at the Midnight crafted base ilvl (197);
#    embellished variants (crafting-effect id set) are skipped.
$craftedBaseIlvl = 197
if ($CraftedIlvl -gt 0) {
    $armorSub = @{ mage=1; priest=1; warlock=1; rogue=2; monk=2; druid=2; demon_hunter=2;
                   hunter=3; shaman=3; evoker=3; warrior=4; paladin=4; death_knight=4 }[$charClass]
    $invSlot  = @{ 1='head'; 3='shoulder'; 5='chest'; 20='chest'; 9='wrist'; 10='hands'; 6='waist'; 7='legs'; 8='feet' }
    $crafted  = [System.Collections.Generic.List[object]]::new()
    # stats-array entry i lives at file line i+1 (line 0 is the array header);
    # entry types 24/25 are the placeholders that crafted_stats= replaces
    $dbLines  = [System.IO.File]::ReadAllLines($itemDb)
    Select-String -Path $itemDb -Pattern ",\s+$craftedBaseIlvl,\s+\d+,\s+0,\s+0,\s+4,\s+\d+,\s+4," | ForEach-Object {
        if ($_.Line -notmatch '^\s*\{\s*"(?<n>.*)",\s*(?<id>\d+),\s*(?<rest>.*)$') { return }
        $name = $Matches.n; $id = [int]$Matches.id
        $f = ($Matches.rest -split ',').ForEach({ $_.Trim() })
        if ([int]$f[3] -ne $craftedBaseIlvl -or [int]$f[7] -ne 4 -or [int]$f[9] -ne 4) { return }
        $flags2 = [Convert]::ToUInt64($f[1].Substring(2), 16)
        if (-not ($flags2 -band 0x4000)) { return }                       # not crafted
        if ([int]$f[24] -ne 0 -or [int]$f[25] -ne 0) { return }           # embellished variant
        $cm = if ($f[17] -like '0x*') { [Convert]::ToUInt64($f[17].Substring(2), 16) } else { [uint64]$f[17] }
        if (($cm -band 0xFFFF) -ne 0xFFFF -and -not ($cm -band $classMaskBit[$charClass])) { return }
        $inv = [int]$f[8]; $sub = [int]$f[10]
        $slot = if ($inv -eq 2  -and $sub -eq 0) { 'neck' }
                elseif ($inv -eq 11 -and $sub -eq 0) { 'finger' }
                elseif ($inv -eq 16) { 'back' }
                elseif ($invSlot[$inv] -and $sub -eq $armorSub) { $invSlot[$inv] }
        if (-not $slot) { return }
        $statTypes = @()
        if ($f[15] -match 'item_stats_data\[(\d+)\]') {
            $idx = [int]$Matches[1]; $n = [int]$f[16]
            $statTypes = foreach ($s in $dbLines[($idx + 1)..($idx + $n)]) {
                if ($s -match '\{\s*(\d+),') { [int]$Matches[1] } }
        }
        $crafted.Add(@{ Id = $id; Name = $name; Slot = $slot
                        Socket    = (($f[19] -replace '\D', '') -ne '0')
                        Moldable  = ($statTypes -contains 24)             # has crafted-stat placeholders
                        Fixed     = @($statTypes | Where-Object { $statName[$_] } | ForEach-Object { $statName[$_] }) })
    }
    Write-Host "Crafted candidates found in item DB: $($crafted.Count) (simming at ilvl $CraftedIlvl)"
    foreach ($c in $crafted) {
        $targetSlots = if ($c.Slot -eq 'finger') { 'finger1', 'finger2' } else { @($c.Slot) }
        foreach ($slot in $targetSlots) {
            $cur = $equipped[$slot]
            if ($cur -and $cur.Id -eq $c.Id) { continue }   # already worn: section 4 covers its stat mixes
            if (Test-OtherSlotHasItem $slot $c.Id) { continue }
            $extra = ''                                      # carry over enchant/gem from displaced item
            if ($cur) {
                if ($cur.Spec -match 'enchant_id=(\d+)') { $extra += ",enchant_id=$($Matches[1])" }
                if ($c.Socket -and $cur.Spec -match 'gem_id=(\d+)') { $extra += ",gem_id=$($Matches[1])" }
            }
            # one freshly-crafted item: 80 Myth crests + Sparks (4 for 2H weapons)
            $craftCost = New-Cost
            $craftCost.crests = $costModel.CraftCrests; $craftCost.tier = 'Myth'
            $craftCost.sparks = if ($slot -in 'main_hand','off_hand') { $costModel.CraftSparks2H } else { $costModel.CraftSparks }
            if ($c.Moldable) {
                foreach ($p in $statPairs) {
                    Add-ProfileSet "craft$CraftedIlvl $($slot): $($c.Name) $($statName[$p[0]])/$($statName[$p[1]])" @(
                        "$slot=,id=$($c.Id),ilevel=$CraftedIlvl$extra,crafted_stats=$($p[0])/$($p[1])") $craftCost
                }
            } else {
                Add-ProfileSet "craft$CraftedIlvl $($slot): $($c.Name) [$($c.Fixed -join '/')]" @(
                    "$slot=,id=$($c.Id),ilevel=$CraftedIlvl$extra") $craftCost
            }
        }
    }
}

# 6) Great Vault choices: as dropped, fully track-upgraded, and (weapons/
#    trinkets on Hero/Myth track) Ascendant Voidforged
foreach ($v in $vault) {
    $baseSlot = $v.Slot -replace '\d$', ''
    if ($v.Slot -in 'main_hand','off_hand' -and -not (Test-Usable $v)) { continue }
    $targetSlots = switch ($baseSlot) {
        'finger'  { 'finger1', 'finger2' }
        'trinket' { 'trinket1', 'trinket2' }
        default   { @($v.Slot) }
    }
    # vault pick itself is free; upgrading it on its track costs crests, and
    # voidforging adds a voidcore (on top of being fully upgraded first)
    $variants = @(); if ($v.Ilvl -ge $MinIlvl) { $variants += @{ Tag = ''; Spec = $v.Spec; Cost = (New-Cost) } }
    if ($maxSpec = Set-MaxTrack $v.Spec) {
        $cc = New-Cost; Add-StepCrests $cc $v.Spec
        $variants += @{ Tag = ' MAXED'; Spec = $maxSpec; Cost = $cc }
    }
    if ($baseSlot -in 'trinket','main_hand','off_hand') {
        if ($vfSpec = Add-Voidforge $v.Spec) {
            $cc = New-Cost; Add-StepCrests $cc $v.Spec; $cc.voidcores += $costModel.Voidcore
            $variants += @{ Tag = ' MAX+VOIDFORGED'; Spec = $vfSpec; Cost = $cc }
        }
    }
    foreach ($slot in $targetSlots) {
        if (Test-OtherSlotHasItem $slot $v.Id) { continue }
        $enchant = if ($equipped[$slot] -and $v.Spec -notmatch 'enchant_id=' -and
                       $equipped[$slot].Spec -match 'enchant_id=(\d+)') { ",enchant_id=$($Matches[1])" } else { '' }
        foreach ($va in $variants) {
            $ov = @("$slot=$($va.Spec)$enchant")
            if ($slot -eq 'main_hand' -and (Test-TwoHand $v) -and $equipped['off_hand']) { $ov += 'off_hand=' }
            Add-ProfileSet "vault $($slot): $($v.Name)$($va.Tag)" $ov $va.Cost
        }
    }
}

# 7) Voidforge upgrades for weapons/trinkets you already own (equipped + bags)
$vfPool = @()
foreach ($s in 'main_hand','off_hand','trinket1','trinket2') { if ($equipped[$s]) { $vfPool += $equipped[$s] } }
$vfPool += $bags | Where-Object { $_.Slot -in 'main_hand','off_hand','trinket1','trinket2' }
foreach ($it in ($vfPool | Group-Object Id | ForEach-Object { $_.Group[0] })) {
    if ($it.Slot -in 'main_hand','off_hand') {
        if (-not (Test-Usable $it)) { continue }
        if ($it.Slot -eq 'off_hand' -and $itemInfo[$it.Id].ItemClass -ne 2) { continue }   # held-in-offhand: not voidforgeable
    }
    $vf = Add-Voidforge $it.Spec
    if (-not $vf) { continue }
    $c = New-Cost; Add-StepCrests $c $it.Spec; $c.voidcores += $costModel.Voidcore   # max first (crests) + voidcore
    $targetSlots = if ($it.Slot -like 'trinket*') { 'trinket1', 'trinket2' } else { @($it.Slot) }
    foreach ($slot in $targetSlots) {
        if (Test-OtherSlotHasItem $slot $it.Id) { continue }
        $ov = @("$slot=$vf")
        if ($slot -eq 'main_hand' -and (Test-TwoHand $it) -and $equipped['off_hand']) { $ov += 'off_hand=' }
        Add-ProfileSet "voidforge $($slot): $($it.Name)" $ov $c
    }
}

# baseline as a profileset: simc reports profilesets as MEDIAN dps but the
# actor table as MEAN - re-equipping one unchanged item gives a baseline
# measured exactly like the alternatives
$blSlot = if ($equipped['head']) { 'head' } else { @($equipped.Keys)[0] }
$blOverride = "$blSlot=$($equipped[$blSlot].Spec)"
Add-ProfileSet 'CURRENT GEAR (baseline)' @($blOverride)

if ($count -le 1) { throw 'No gear alternatives found in the export (no bag items / crafted gear).' }
Write-Host "Generated $count gear variants to simulate."

# ------------------------------------------------------------------ run ----
$stamp    = Get-Date -Format 'yyyyMMdd_HHmm'
$base     = Join-Path $outDir ("{0}_gearscan_{1}" -f ($charName -replace '[^\w-]', ''), $stamp)
$genFile  = "$base.simc"; $txtFile = "$base.txt"; $reportFile = "$base`_report.html"

$body = $text.TrimEnd() + "`n`n# ---- generated by gear-options.ps1 ----`n" + ($gen -join "`n") + "`n"
Set-Content -Path $genFile -Value $body -Encoding UTF8
if ($DryRun) { Write-Host "Dry run - wrote $genFile"; return }

# FILTER scan: rank every variant at the (loose) $TargetError. This stage only
# needs to rank the field and fill the table - the winners are re-simmed precisely
# in the refine stage below - so it runs deliberately loose for speed (see -TargetError).
$simArgs = @($genFile, "target_error=$TargetError", 'threads=0', "output=$txtFile")
if ($FightStyle) { $simArgs += "fight_style=$FightStyle" }

Write-Host "Filter scan: $count variants at target_error=$TargetError$(if ($FightStyle) { ", fight_style=$FightStyle" })..." -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$simErrors = [System.Collections.Generic.List[string]]::new()
& $simcExe @simArgs 2>&1 | ForEach-Object {
    if ($_ -match 'error') { $simErrors.Add([string]$_) }
    if ($_ -match 'Generating|Profileset.+\d+/\d+|ERROR') { Write-Host "  $_" }
}
if ($LASTEXITCODE -ne 0) { throw "simc failed (exit $LASTEXITCODE): $($simErrors -join ' | ')" }
$sw.Stop()
Write-Host ("Done in {0:n1}s." -f $sw.Elapsed.TotalSeconds)

# -------------------------------------------------------------- results ----
$out = Get-Content $txtFile
$baseDps = $null
foreach ($l in $out) { if ($l -match "^\s*(\d+(?:\.\d+)?)\s+[\d.]+%\s+$([regex]::Escape($charName))\s*$") { $baseDps = [double]$Matches[1]; break } }

$results = [System.Collections.Generic.List[object]]::new()
$inPs = $false
foreach ($l in $out) {
    if ($l -match '^Profilesets') { $inPs = $true; continue }
    if ($inPs) {
        if ($l -match '^\s*([\d.]+)\s*:\s*(.+?)\s*$') {
            $results.Add([pscustomobject]@{ Dps = [double]$Matches[1]; Option = $Matches[2] })
        } elseif ($l -notmatch '\S') { if ($results.Count -gt 0) { break } }
    }
}
# prefer the baseline profileset (median, same metric as all other rows);
# fall back to the actor-table mean if it is missing for some reason
$basePs = $results | Where-Object { $_.Option -eq 'CURRENT GEAR (baseline)' } | Select-Object -First 1
if ($basePs) {
    $baseDps = $basePs.Dps
    $basePs.Option = '>>> CURRENT GEAR (baseline) <<<'
} elseif ($baseDps) {
    $results.Add([pscustomobject]@{ Dps = $baseDps; Option = '>>> CURRENT GEAR (baseline) <<<' })
}

# ----------------------------------------------- beam-search upgrade path ----
# Greedy (best single slot, repeat) can miss the best SET when two picks share a
# secondary stat (two Crit/Mastery pieces overlap; Crit/Mastery + Crit/Haste can
# total more). So we beam-search: per slot keep the top few stat/upgrade variants
# as candidates, then at each depth expand the current best states by one more
# slot, MEASURE the combos, and keep the best $BeamWidth. For each N we report the
# best measured set of N changes. Exploration runs at the loose filter
# target_error (cheap); the chosen best-per-N sets + their items are refined at 0.05.
$priority = [System.Collections.Generic.List[object]]::new()
if ($baseDps) {
    function Get-Family([string]$option) {
        $slots = @($psMeta[$option] | ForEach-Object { ($_ -split '=', 2)[0] })
        if ($slots -match '^finger') { 'fingers' }
        elseif ($slots -match '^trinket') { 'trinkets' }
        elseif ($slots -match '^(main|off)_hand') { 'weapons' }
        else { $slots[0] }
    }
    # candidate pool: per slot family, the top $BeamVariants gain options
    $candFloor = 0.1            # % gain in the filter scan to be a candidate at all
    $poolByFam = [ordered]@{}
    foreach ($r in ($results | Sort-Object Dps -Descending)) {
        if ($r.Option -like '>>>*' -or $r.Option -like 'ALL BEST*') { continue }
        if (($r.Dps / $baseDps - 1) * 100 -le $candFloor) { break }
        if (-not $psMeta[$r.Option]) { continue }
        $f = Get-Family $r.Option
        if (-not $poolByFam.Contains($f)) { $poolByFam[$f] = [System.Collections.Generic.List[object]]::new() }
        if ($poolByFam[$f].Count -lt $BeamVariants) { $poolByFam[$f].Add($r) }
    }
    $families = @($poolByFam.Keys)
    if ($families.Count -ge 1) {
        $reStr = ([math]::Min($TargetError, 0.05)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $exStr = $TargetError.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $maxDepth = [math]::Min($families.Count, $MaxChanges)
        Write-Host "Beam search (width $BeamWidth, $($families.Count) slots x<=$BeamVariants variants, depth $maxDepth) at target_error=$exStr..." -ForegroundColor Cyan

        function Overrides-Of($picks) { $o = @(); foreach ($f in $picks.Keys) { $o += $psMeta[$picks[$f].Option] }; $o }
        function Key-Of($picks) { ($picks.Keys | Sort-Object | ForEach-Object { "$_=$($picks[$_].Option)" }) -join '|' }

        $beam = @( @{ Picks = @{}; Dps = $baseDps } )       # depth-0 = current gear
        $bestPerDepth = @{}                                  # int depth -> best state (hashtable: int keys)
        for ($d = 1; $d -le $maxDepth; $d++) {
            $cand = @{}
            foreach ($s in $beam) {
                foreach ($f in $families) {
                    if ($s.Picks.ContainsKey($f)) { continue }
                    foreach ($opt in $poolByFam[$f]) {
                        $np = @{}; foreach ($k in $s.Picks.Keys) { $np[$k] = $s.Picks[$k] }; $np[$f] = $opt
                        $cand[(Key-Of $np)] = $np
                    }
                }
            }
            if ($cand.Count -eq 0) { break }
            $keys = @($cand.Keys)
            $cgen = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $keys.Count; $i++) { foreach ($o in (Overrides-Of $cand[$keys[$i]])) { $cgen.Add("profileset.`"S$i`"+=$o") } }
            $cgen.Add("profileset.`"CURRENT GEAR (baseline)`"+=$blOverride")
            $bFile = "$base`_beam$d.simc"; $bTxt = "$base`_beam$d.txt"
            Set-Content -Path $bFile -Value ($text.TrimEnd() + "`n`n" + ($cgen -join "`n") + "`n") -Encoding UTF8
            $bArgs = @($bFile, "target_error=$exStr", 'threads=0', "output=$bTxt"); if ($FightStyle) { $bArgs += "fight_style=$FightStyle" }
            & $simcExe @bArgs 2>&1 | Out-Null
            $sb = $null; $sdps = @{}
            foreach ($l in (Get-Content $bTxt -ErrorAction SilentlyContinue)) {
                if ($l -match '^\s*([\d.]+)\s*:\s*S(\d+)\s*$') { $sdps[[int]$Matches[2]] = [double]$Matches[1] }
                elseif ($l -match '^\s*([\d.]+)\s*:\s*CURRENT GEAR \(baseline\)') { $sb = [double]$Matches[1] }
            }
            if (-not $sb) { break }
            $scored = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt $keys.Count; $i++) { if ($sdps.ContainsKey($i)) {
                $scored.Add([pscustomobject]@{ Picks = $cand[$keys[$i]]; Dps = $baseDps * ($sdps[$i] / $sb) }) } }
            $scored = @($scored | Sort-Object Dps -Descending)
            if ($scored.Count -eq 0) { break }
            $beam = @($scored | Select-Object -First $BeamWidth)
            $bestPerDepth[$d] = $scored[0]
            if ($d -ge 2 -and $bestPerDepth[$d].Dps -le $bestPerDepth[$d - 1].Dps) { break }   # plateau: more changes don't help
        }

        # refine: the unique items (for table rows) + each depth's best set, at 0.05
        if ($bestPerDepth.Count -ge 1) {
            $uniq = [ordered]@{}
            foreach ($d in $bestPerDepth.Keys) { foreach ($f in $bestPerDepth[$d].Picks.Keys) {
                $rr = $bestPerDepth[$d].Picks[$f]; if (-not $uniq.Contains($rr.Option)) { $uniq[$rr.Option] = $rr } } }
            $uniqKeys = @($uniq.Keys)
            $depths = @($bestPerDepth.Keys | Sort-Object)
            Write-Host "Refining $($uniqKeys.Count) items + $($depths.Count) best sets at target_error=$reStr..." -ForegroundColor Cyan
            $cgen = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $uniqKeys.Count; $i++) { foreach ($o in $psMeta[$uniqKeys[$i]]) { $cgen.Add("profileset.`"SOLO $i`"+=$o") } }
            foreach ($d in $depths) { foreach ($o in (Overrides-Of $bestPerDepth[$d].Picks)) { $cgen.Add("profileset.`"SET $d`"+=$o") } }
            $cgen.Add("profileset.`"CURRENT GEAR (baseline)`"+=$blOverride")
            $cFile = "$base`_refine.simc"; $cTxt = "$base`_refine.txt"
            Set-Content -Path $cFile -Value ($text.TrimEnd() + "`n`n" + ($cgen -join "`n") + "`n") -Encoding UTF8
            $cArgs = @($cFile, "target_error=$reStr", 'threads=0', "output=$cTxt"); if ($FightStyle) { $cArgs += "fight_style=$FightStyle" }
            & $simcExe @cArgs 2>&1 | Out-Null
            $solo = @{}; $set = @{}; $stageBase = $null
            foreach ($l in (Get-Content $cTxt -ErrorAction SilentlyContinue)) {
                if ($l -match '^\s*([\d.]+)\s*:\s*SOLO (\d+)\s*$') { $solo[[int]$Matches[2]] = [double]$Matches[1] }
                elseif ($l -match '^\s*([\d.]+)\s*:\s*SET (\d+)\s*$') { $set[[int]$Matches[2]] = [double]$Matches[1] }
                elseif ($l -match '^\s*([\d.]+)\s*:\s*CURRENT GEAR \(baseline\)') { $stageBase = [double]$Matches[1] }
            }
            if ($stageBase) {
                $soloByOpt = @{}
                for ($i = 0; $i -lt $uniqKeys.Count; $i++) { if ($solo.ContainsKey($i)) {
                    $v = $baseDps * ($solo[$i] / $stageBase); $soloByOpt[$uniqKeys[$i]] = $v
                    $uniq[$uniqKeys[$i]].Dps = $v } }                                  # overwrite table row (same object ref)
                $prev = $baseDps
                foreach ($d in $depths) {
                    $picks = $bestPerDepth[$d].Picks
                    $opts  = @($picks.Keys | ForEach-Object { $picks[$_].Option })
                    # depth 1 == a single item: use its solo so it matches the table row exactly
                    $cd = if ($d -eq 1 -and $soloByOpt.ContainsKey($opts[0])) { $soloByOpt[$opts[0]] }
                          elseif ($set.ContainsKey($d)) { $baseDps * ($set[$d] / $stageBase) } else { $null }
                    if (-not $cd) { continue }
                    $setCost = New-Cost; foreach ($o in $opts) { if ($psCost[$o]) { Merge-Cost $setCost $psCost[$o] | Out-Null } }
                    $priority.Add([pscustomobject]@{
                        Step    = $d
                        Items   = $opts
                        Cost    = $setCost
                        CumDps  = $cd
                        CumPct  = ($cd - $baseDps) / $baseDps * 100
                        MargPct = ($cd - $prev) / $baseDps * 100
                    })
                    $prev = $cd
                }
                # surface the best full set in the main table (refined)
                if ($priority.Count -ge 1) {
                    $last = $priority[$priority.Count - 1]
                    if ($last.Items.Count -ge 2) {
                        $comboName = "ALL BEST UPGRADES COMBINED:  " + ($last.Items -join '  +  ')
                        $psCost[$comboName] = $last.Cost
                        $results.Add([pscustomobject]@{ Dps = $last.CumDps; Option = $comboName })
                    }
                }
            }
        }
    }
}

Write-Host ''
Write-Host ("{0,12}  {1,8}  {2}" -f 'DPS', 'Change', 'Option') -ForegroundColor White
Write-Host ("{0,12}  {1,8}  {2}" -f '---', '------', '------')
$lines = foreach ($r in ($results | Sort-Object Dps -Descending)) {
    $delta = if ($baseDps) { ($r.Dps - $baseDps) / $baseDps * 100 } else { 0 }
    $row = "{0,12:n0}  {1,7:+0.00;-0.00;0.00}%  {2}" -f $r.Dps, $delta, $r.Option
    $color = if ($r.Option -like '>>>*') { 'Yellow' } elseif ($delta -gt 0.05) { 'Green' } elseif ($delta -lt -0.05) { 'DarkGray' } else { 'Gray' }
    Write-Host $row -ForegroundColor $color
    $row
}
$lines | Set-Content "$base`_results.txt"

# ----------------------------------------- interactive HTML report ----------
$meta = [pscustomobject]@{
    Name      = $charName
    Class     = $charClass
    Spec      = $charSpec
    Fight     = if ($FightStyle) { $FightStyle } else { 'Single target (Patchwerk)' }
    TargetErr = $TargetError
    RefineErr = [math]::Min($TargetError, 0.05)
    BaseDps   = $baseDps
    Stamp     = (Get-Date -Format 'yyyy-MM-dd HH:mm')
}
function ConvertTo-CostObj($c) {
    if (-not $c) { $c = New-Cost }
    [pscustomobject]@{ crests = [int]$c.crests; tier = $c.tier; sparks = [int]$c.sparks
                       voidcores = [int]$c.voidcores; gold = [bool]$c.gold }
}
# 1-sigma error on a delta% = sqrt(te_row^2 + te_baseline^2). Refined rows
# (winners/combined/priority) were re-simmed against the tight baseline; the
# rest ride on the broad scan's target_error.
$refineErrUsed = [math]::Min($TargetError, 0.05)
$broadDeltaErr  = [math]::Round([math]::Sqrt(2) * $TargetError, 3)
$refineDeltaErr = [math]::Round([math]::Sqrt(2) * $refineErrUsed, 3)
$refinedOpts = [System.Collections.Generic.HashSet[string]]::new()
foreach ($p in $priority) { foreach ($o in $p.Items) { [void]$refinedOpts.Add($o) } }
foreach ($r in $results) { if ($r.Option -like 'ALL BEST UPGRADES COMBINED:*') { [void]$refinedOpts.Add($r.Option) } }
$rowData = foreach ($r in ($results | Sort-Object Dps -Descending)) {
    [pscustomobject]@{ dps = [math]::Round($r.Dps); opt = $r.Option
                       delta = if ($baseDps) { [math]::Round(($r.Dps - $baseDps) / $baseDps * 100, 2) } else { 0 }
                       err  = if ($refinedOpts.Contains($r.Option)) { $refineDeltaErr } else { $broadDeltaErr }
                       cost = ConvertTo-CostObj $psCost[$r.Option] }
}
$prioData = foreach ($p in $priority) {
    [pscustomobject]@{ step = $p.Step; items = @($p.Items); cumDps = [math]::Round($p.CumDps)
                       cumPct = [math]::Round($p.CumPct, 2); margPct = [math]::Round($p.MargPct, 2)
                       err  = $refineDeltaErr
                       cost = ConvertTo-CostObj $p.Cost }
}
New-GearReport -Path $reportFile -Meta $meta -Rows @($rowData) -Priority @($prioData)
Write-Host ''
Write-Host "Saved: $base`_results.txt / _report.html / .simc"
if (-not $NoBrowser) { Start-Process $reportFile }
