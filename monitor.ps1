# monitor.ps1
# Samples system metrics periodically, appends JSON lines to monitor_data.jsonl
# and regenerates dashboard.html (self-contained view).

$DataFile = Join-Path $PSScriptRoot 'monitor_data.jsonl'
$HtmlFile = Join-Path $PSScriptRoot 'dashboard.html'
$Interval = 2            # seconds between samples
$RetentionDays = 7       # retention window in days (1 week)
# compute number of samples to keep (rounded up)
$Keep = [int]([math]::Ceiling(($RetentionDays * 24 * 3600) / $Interval))

if (-not (Test-Path $DataFile)) { New-Item -Path $DataFile -ItemType File | Out-Null }

while ($true) {
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # CPU average load
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $cpu = if ($cpu -eq $null) { 0 } else { [math]::Round($cpu,2) }

    # Memory percent used
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os) {
        $memPercent = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory)/$os.TotalVisibleMemorySize)*100,2)
    } else { $memPercent = 0 }

    # Disk free percent for C:
    try {
        $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        if ($ld -and $ld.Size -gt 0) {
            $diskFreePercent = [math]::Round((($ld.FreeSpace / $ld.Size) * 100),2)
        } else { $diskFreePercent = 0 }
    } catch { $diskFreePercent = 0 }

    # Network bytes (sum of adapters since boot)
    try {
        $netStats = Get-NetAdapterStatistics | Measure-Object -Property ReceivedBytes,SentBytes -Sum
        $netBytes = ($netStats.SumReceivedBytes + $netStats.SumSentBytes)
    } catch { $netBytes = 0 }

    $obj = [pscustomobject]@{
        Time            = $time
        CPU             = $cpu
        MemoryPercent   = $memPercent
        DiskFreePercent = $diskFreePercent
        NetworkBytes    = $netBytes
    }

    $obj | ConvertTo-Json -Compress | Out-File -FilePath $DataFile -Append -Encoding utf8

    # Trim file to last $Keep lines
    $lines = Get-Content $DataFile -Tail $Keep
    $lines | Set-Content $DataFile -Encoding utf8

    # ---------  BUILD HTML  ---------
    $dataFileName = Split-Path $DataFile -Leaf
    $updated      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    # single-quoted here-string → JS ${…} left untouched by PowerShell
    $html = @'
<!doctype html>
<html>
<head>
<meta charset='utf-8'>
<title>Local PC Monitor</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
/*  CSS VARIABLES  */
:root{
  --bg:#f6f8fa; --card:#ffffff; --text:#111317; --muted:#6b7280; --accent:#0a84ff;
  --cpu:#ff6b6b; --ram:#6bc1ff; --disk:#8ce99a; --net:#ffd43b; --kill:#ff4d4d;
  --shadow:0 8px 24px rgba(15,23,42,.08); --radius:14px; --font:"Segoe UI",Roboto,Arial,sans-serif;
  --resize-h:12px; --resize-w:12px;
  --transition:.25s ease;
}
/*  DARK THEME  */
@media (prefers-color-scheme:dark){
  :root{ --bg:#0d1117; --card:#161b22; --text:#e6edf3; --muted:#8b949e; }
}
[data-theme="dark"]{ --bg:#0d1117; --card:#161b22; --text:#e6edf3; --muted:#8b949e; }
[data-theme="light"]{ --bg:#f6f8fa; --card:#fff; --text:#111317; --muted:#6b7280; }

/*  GLOBAL  */
*{box-sizing:border-box;font-family:var(--font);}
body{background:var(--bg);color:var(--text);margin:0;padding:24px;font-size:14px;line-height:1.45;}
button,input,select{background:var(--card);color:var(--text);border:1px solid var(--muted);border-radius:8px;padding:8px 12px;font-size:13px;transition:var(--transition);}
button{cursor:pointer}button:hover{border-color:var(--accent);transform:translateY(-1px);}
input[type="datetime-local"]{width:100%;max-width:200px;}

/*  HEADER  */
.header{display:flex;align-items:center;justify-content:space-between;gap:20px;margin-bottom:24px;flex-wrap:wrap;}
.brand{display:flex;align-items:center;gap:12px;}
.logo{width:36px;height:36px;background:var(--accent);border-radius:50%;display:grid;place-content:center;color:#fff;font-weight:700;font-size:18px;}
.brand h1{font-size:24px;margin:0;font-weight:600;}
.live-clock{font-size:13px;color:var(--muted);}
.controls{display:flex;align-items:center;gap:10px;}
#themeToggle{width:36px;height:36px;border-radius:50%;padding:0;font-size:18px;background:var(--card);border:1px solid var(--muted);}

/*  FILTER BAR  */
.filter-bar{display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin-bottom:20px;}
.filter-bar label{font-size:13px;color:var(--muted);}
.quick-btns{display:flex;gap:6px;}
.quick-btns button{font-size:12px;padding:6px 10px;}

/*  CARDS  */
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:18px;}
.card{background:var(--card);padding:18px;border-radius:var(--radius);box-shadow:var(--shadow);position:relative;overflow:hidden;resize:block;transition:var(--transition);}
.card:hover{box-shadow:0 12px 32px rgba(15,23,42,.1);}
.card h3{margin:0 0 12px;font-size:17px;font-weight:600;display:flex;align-items:center;gap:8px;}
.resize{position:absolute;bottom:0;right:0;width:var(--resize-w);height:var(--resize-h);cursor:nw-resize;background:linear-gradient(135deg,transparent 40%,var(--muted) 100%);opacity:.2;transition:opacity .2s}
.card:hover .resize{opacity:.5}

/*  CHART  */
.canvasWrap{width:100%;height:220px;background:linear-gradient(180deg,var(--card),var(--bg));border-radius:10px;padding:10px;box-sizing:border-box;cursor:zoom-in;position:relative;}
canvas{width:100%;height:100%;}
/* fullscreen mode */
body:has(.fullscreen){overflow:hidden;}
.fullscreen{position:fixed;inset:24px;z-index:999;resize:none;}
.fullscreen .canvasWrap{height:calc(100vh - 200px);}
.close-full{position:absolute;top:14px;right:14px;background:var(--kill);color:#fff;border:none;padding:6px 10px;font-size:12px;border-radius:6px;}

/* loading overlay for fullscreen zoom */
.loading-overlay{
  position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;
  background:rgba(255,255,255,0.65);backdrop-filter:blur(4px);border-radius:8px;pointer-events:none;
}
[data-theme="dark"] .loading-overlay{ background: rgba(10,10,12,0.6); color:var(--text); }
.loading-overlay .spinner{
  width:36px;height:36px;border-radius:50%;border:4px solid rgba(0,0,0,0.08);border-top-color:var(--accent);animation:spin .9s linear infinite;margin-bottom:8px;
}
@keyframes spin{ to{ transform:rotate(360deg); } }

/*  TOOLTIP  */
.tooltip{position:absolute;background:rgba(0,0,0,.85);color:#fff;padding:6px 10px;border-radius:6px;font-size:12px;pointer-events:none;z-index:1000;transform:translate(-50%,-100%);margin-top:-8px;white-space:nowrap;}

/*  KILL CARD  */
.kill-row{display:flex;align-items:center;gap:12px;margin-top:10px;}
.kill-row button{background:var(--kill);color:#fff;border:none;}
.kill-row button:hover{background:#ff1a1a;}

/*  FOOTER  */
footer{margin-top:24px;text-align:right;color:var(--muted);font-size:12px;}

/*  THEME SWITCH  */
.theme-switch{position:relative;display:inline-block;width:56px;height:28px;vertical-align:middle}
.theme-switch input{opacity:0;width:0;height:0;margin:0}
.theme-switch .slider{position:absolute;cursor:pointer;top:0;left:0;right:0;bottom:0;background:#d6d8dd;border-radius:28px;transition:background .18s}
.theme-switch .slider:before{position:absolute;content:"";height:22px;width:22px;left=3px;top=3px;background:#fff;border-radius:50%;transition:transform .18s;box-shadow:0 2px 6px rgba(0,0,0,0.12)}
.theme-switch input:checked + .slider{background:var(--accent)}
.theme-switch input:checked + .slider:before{transform:translateX(28px)}
</style>
</head>
<body>
<div class="container">

  <!--  HEADER  -->
  <div class="header">
    <div class="brand">
      <div class="logo">PC</div>
      <h1>Local PC Monitor</h1>
    </div>
    <div class="live-clock" id="updated">Updated: {{UPDATED}}</div>
    <div class="controls">
      <label class="theme-switch" aria-hidden="true">
        <input type="checkbox" id="themeToggle" aria-label="Toggle theme">
        <span class="slider"></span>
      </label>
      <span class="small" style="margin-left:8px">Theme</span>
      <label class="small"><input id="autoRefresh" type="checkbox" checked> Auto</label>
      <button id="refresh" class="btn">Refresh</button>
      <div id="status" class="status"></div>
    </div>
  </div>

  <!--  FILTER BAR  -->
  <div class="filter-bar">
    <label>From <input type="datetime-local" id="fromPicker"></label>
    <label>To   <input type="datetime-local" id="toPicker"></label>
    <div class="quick-btns">
      <button data-range="1h">Last hour</button>
      <button data-range="6h">Last 6 h</button>
      <button data-range="24h">Last 24 h</button>
      <button data-range="today">Today</button>
      <button data-range="yesterday">Yesterday</button>
    </div>
  </div>

  <!--  CARDS  -->
  <div class="grid">
    <div class="card" id="cpuCard">
      <h3><span class="dot" style="background:var(--cpu)"></span>CPU %</h3>
      <div class="canvasWrap" ondblclick="openFullScreen('cpuCard')"><canvas id="cpuCanvas"></canvas></div>
      <div class="resize"></div>
    </div>
    <div class="card" id="ramCard">
      <h3><span class="dot" style="background:var(--ram)"></span>Memory %</h3>
      <div class="canvasWrap" ondblclick="openFullScreen('ramCard')"><canvas id="ramCanvas"></canvas></div>
      <div class="resize"></div>
    </div>
    <div class="card" id="diskCard">
      <h3><span class="dot" style="background:var(--disk)"></span>Disk free %</h3>
      <div class="canvasWrap" ondblclick="openFullScreen('diskCard')"><canvas id="diskCanvas"></canvas></div>
      <div class="resize"></div>
    </div>
    <div class="card" id="netCard">
      <h3><span class="dot" style="background:var(--net)"></span>Network bytes</h3>
      <div class="canvasWrap" ondblclick="openFullScreen('netCard')"><canvas id="netCanvas"></canvas></div>
      <div class="resize"></div>
    </div>

    <!--  KILL CARD  -->
    <div class="card" id="killCard">
      <h3>Monitor process</h3>
      <div class="kill-row">
        <span>PID: <strong id="monPID">--</strong></span>
        <button onclick="killMonitor()">Kill monitor</button>
      </div>
      <div class="resize"></div>
    </div>
  </div>

  <!--  RAW FILE INFO  -->
  <div class="card" style="margin-top:18px">
    <div style="display:flex;justify-content:space-between;font-size:13px;color:var(--muted)">
      <span>Raw file: <code>{{DATAFILE}}</code></span>
      <span>Showing <span id="sampleCount">0</span> samples</span>
    </div>
  </div>

  <footer class="small">Open via local server (monitor.bat → “Open HTML view”) to avoid CORS limits.</footer>
</div>

<script>
/* ----------  CONFIG  ---------- */
const dataFile = "./{{DATAFILE}}";
let lines = [];
let filtered = [];
let refreshInterval = 4000;
let autoRefresh = true;

/* ----------  THEME  ---------- */
const themeToggle = document.getElementById('themeToggle');
function applyTheme(){
  const m = localStorage.theme || (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  document.documentElement.setAttribute('data-theme', m);
  if (themeToggle) themeToggle.checked = (m === 'dark');
}
applyTheme();
if (themeToggle) {
  themeToggle.onchange = (e) => {
    localStorage.theme = e.target.checked ? 'dark' : 'light';
    applyTheme();
  };
}

/* ----------  FULL-SCREEN GRAPH  ---------- */
function openFullScreen(cardId){
  const card = document.getElementById(cardId);
  if(!card) return;
  // show fullscreen class
  card.classList.add('fullscreen');

  // add close button if not present
  if(!card.querySelector('.close-full')){
    const closeBtn = document.createElement('button');
    closeBtn.textContent='X'; closeBtn.className='close-full';
    closeBtn.onclick=()=>{ card.classList.remove('fullscreen'); closeBtn.remove(); };
    card.appendChild(closeBtn);
  }

  // ensure loading overlay exists and show it
  let overlay = card.querySelector('.loading-overlay');
  if(!overlay){
    overlay = document.createElement('div');
    overlay.className = 'loading-overlay';
    overlay.innerHTML = '<div class="spinner"></div><div class="small">Loading...</div>';
    // put overlay inside the canvasWrap so it covers the graph area
    const wrap = card.querySelector('.canvasWrap') || card;
    wrap.style.position = 'relative';
    wrap.appendChild(overlay);
  }
  overlay.style.display = 'flex';
  overlay.style.pointerEvents = 'none';

  // allow layout to stabilize, then redraw charts and hide overlay
  // small delay helps when zoom / CSS transitions occur
  requestAnimationFrame(()=> {
    // extra micro-delay to ensure browser has applied the fullscreen layout
    setTimeout(()=>{
      // redraw only charts to be quick
      try { renderAll(); } catch(e){ /* fallback */ fetchLines(); }
      overlay.style.display = 'none';
    }, 180);
  });
}

/* ----------  FILTER LOGIC  ---------- */
const fromPicker = document.getElementById('fromPicker');
const toPicker   = document.getElementById('toPicker');
function setPickers(from,to){
  fromPicker.value = from.toISOString().slice(0,16);
  toPicker.value   = to.toISOString().slice(0,16);
}
function resetFilters(){
  const now = new Date();
  const oneHourAgo = new Date(now - 3600_000);
  setPickers(oneHourAgo, now);
}
resetFilters();

function getRangeMs(range){
  const now = new Date();
  switch(range){
    case '1h':  return [now - 3600_000, now];
    case '6h':  return [now - 6*3600_000, now];
    case '24h': return [now - 24*3600_000, now];
    case 'today':
      const startToday = new Date(now); startToday.setHours(0,0,0,0);
      return [startToday, now];
    case 'yesterday':
      const yStart = new Date(now); yStart.setDate(yStart.getDate()-1); yStart.setHours(0,0,0,0);
      const yEnd   = new Date(yStart); yEnd.setHours(23,59,59,999);
      return [yStart, yEnd];
    default: return [new Date(0), now];
  }
}
document.querySelectorAll('.quick-btns button').forEach(btn=>{
  btn.onclick = () => { const [f,t] = getRangeMs(btn.dataset.range); setPickers(f,t); applyFilter(); };
});
[fromPicker, toPicker].forEach(p=>p.onchange = applyFilter);

function applyFilter(){
  const from = new Date(fromPicker.value);
  const to   = new Date(toPicker.value);
  filtered = lines.filter(l=>{
    const d = parseLine(l);
    if(!d) return false;
    const t = new Date(d.Time);
    return t >= from && t <= to;
  });
  renderAll();
}

/* ----------  DATA FETCH  ---------- */
function parseLine(l){ try{ return JSON.parse(l); }catch{return null;} }
function fetchLines(){
  document.getElementById('status').textContent = 'Loading…';
  return fetch(dataFile + '?_=' + Date.now())
    .then(r=>r.text())
    .then(t=>{
      lines = t.split(/\r?\n/).filter(l=>l.trim());
      document.getElementById('updated').textContent = 'Updated: ' + new Date().toLocaleString();
      document.getElementById('sampleCount').textContent = lines.length;
      applyFilter();
      showMonitorPID();
    })
    .catch(err=>{ document.getElementById('status').textContent = 'Error loading data'; });
}
document.getElementById('refresh').onclick = fetchLines;
document.getElementById('autoRefresh').onchange = e => autoRefresh = e.target.checked;

/* ----------  KILL MONITOR  ---------- */
function showMonitorPID(){
  fetch('./pid?_='+Date.now())
    .then(r=>r.text())
    .then(txt=>{ document.getElementById('monPID').textContent = txt.trim(); })
    .catch(()=>{ document.getElementById('monPID').textContent = '??'; });
}
function killMonitor(){
  const pid = document.getElementById('monPID').textContent;
  if(!pid || pid==='--' || pid==='??') return;
  fetch('./kill?pid='+pid,{method:'POST'}).then(()=>{
    document.getElementById('monPID').textContent = 'killed';
  });
}

/* ----------  RENDER  ---------- */
function renderAll(){
  renderChart('cpuCanvas',  filtered, 'CPU',      'CPU %',         '#ff6b6b');
  renderChart('ramCanvas',  filtered, 'MemoryPercent', 'Memory %', '#6bc1ff');
  renderChart('diskCanvas', filtered, 'DiskFreePercent','Disk free %','#8ce99a');
  renderChart('netCanvas',  filtered, 'NetworkBytes','Network bytes','#ffd43b');
  document.getElementById('status').textContent = '';
}

function renderChart(canvasId, data, metric, label, color){
  const canvas = document.getElementById(canvasId);
  const ctx = canvas.getContext('2d');
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth * dpr;
  const h = canvas.clientHeight * dpr;
  canvas.width = w; canvas.height = h;
  ctx.clearRect(0,0,w,h);

  const vals = data.map(l=>parseLine(l)).filter(d=>d&& d[metric]!=null).map(d=>Number(d[metric]));
  const times = data.map(l=>parseLine(l)).filter(d=>d&& d[metric]!=null).map(d=>d.Time);
  if(!vals.length){ ctx.fillStyle = '#999'; ctx.font = `${12*dpr}px sans-serif`; ctx.fillText('No data',10*dpr,20*dpr); return;}

  const min = Math.min(...vals), max = Math.max(...vals);
  const pad = 40*dpr, plotW = w - 2*pad, plotH = h - 2*pad;

  // grid + axes
  ctx.strokeStyle = 'rgba(0,0,0,.08)'; ctx.lineWidth = 1;
  for(let i=0;i<=4;i++){
    const y = pad + (plotH/4)*i;
    ctx.beginPath(); ctx.moveTo(pad,y); ctx.lineTo(pad+plotW,y); ctx.stroke();
    ctx.fillStyle = '#666'; ctx.font = `${10*dpr}px sans-serif`;
    ctx.fillText(round(max - (max-min)/4*i), 5*dpr, y+3*dpr);
  }
  // axis bottom
  ctx.beginPath(); ctx.moveTo(pad, pad+plotH); ctx.lineTo(pad+plotW, pad+plotH); ctx.stroke();

  // area
  ctx.beginPath();
  vals.forEach((v,i)=>{
    const x = pad + (i/(vals.length-1))*plotW;
    const y = pad + (1 - (v-min)/Math.max(0.0001,max-min))*plotH;
    if(i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
  });
  ctx.lineTo(pad+plotW, pad+plotH); ctx.lineTo(pad, pad+plotH); ctx.closePath();
  const grad = ctx.createLinearGradient(0,pad,0,pad+plotH);
  grad.addColorStop(0, hexToRgba(color,0.28));
  grad.addColorStop(1, hexToRgba(color,0.02));
  ctx.fillStyle = grad; ctx.fill();
  // line
  ctx.beginPath();
  vals.forEach((v,i)=>{
    const x = pad + (i/(vals.length-1))*plotW;
    const y = pad + (1 - (v-min)/Math.max(0.0001,max-min))*plotH;
    if(i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
  });
  ctx.strokeStyle = color; ctx.lineWidth = 2.5*dpr; ctx.stroke();

  // legend
  ctx.fillStyle = '#555';
  ctx.font = `${12*dpr}px sans-serif`;
  ctx.fillText(`${label}  (min:${round(min)}  max:${round(max)})`, pad, 14*dpr);

  // store data for hover
  canvas.chartData = {vals, times, min, max, pad, plotW, plotH, label, color};
}

/* ----------  HOVER TOOLTIP  ---------- */
let tip = null;
function createTip(){
  if(tip) return;
  tip = document.createElement('div');
  tip.className='tooltip';
  document.body.appendChild(tip);
}
function removeTip(){ if(tip) { tip.remove(); tip=null; } }

// create tooltip once
createTip();

document.querySelectorAll('canvas').forEach(canvas=>{
  canvas.addEventListener('mousemove', e=>{
    if(!canvas.chartData) return;
    const {vals, times, min, max, pad, plotW, plotH, label} = canvas.chartData;
    const rect = canvas.getBoundingClientRect();
    const x = (e.clientX - rect.left) * (canvas.width/rect.width);
    const idx = Math.round((x - pad) / plotW * (vals.length-1));
    if(idx<0||idx>=vals.length) { tip.style.display='none'; return; }
    const v = vals[idx]; const t = times[idx];
    if(t==null||v==null) { tip.style.display='none'; return; }
    tip.textContent = `${t}   ${label}: ${round(v)}`;
    tip.style.display='block';
    tip.style.left = e.clientX + 'px';
    tip.style.top  = e.clientY + 'px';
    tip.style.transform = 'translate(-50%,-100%)';
    tip.style.marginTop = '-8px';
  });
  canvas.addEventListener('mouseleave', ()=> tip && (tip.style.display='none') );
});
/* ----------  UTILS  ---------- */
function round(v){ return Math.round(v*100)/100; }
function hexToRgba(hex,a){
  hex=hex.replace('#','');
  const r=parseInt(hex.substring(0,2),16), g=parseInt(hex.substring(2,4),16), b=parseInt(hex.substring(4,6),16);
  return `rgba(${r},${g},${b},${a})`;
}

/* ----------  AUTO REFRESH  ---------- */
setInterval(()=>{ if(autoRefresh) fetchLines(); }, refreshInterval);
fetchLines();
</script>
</body>
</html>
'@

    # inject dynamic tokens
    $html = $html.Replace('{{DATAFILE}}', $dataFileName)
    $html = $html.Replace('{{UPDATED}}', $updated)

    $html | Set-Content $HtmlFile -Encoding utf8

    Start-Sleep -Seconds $Interval
}