# monitor.ps1
# Samples system metrics periodically, appends JSON lines to monitor_data.jsonl
# and regenerates dashboard.html (self-contained view).

$DataFile = Join-Path $PSScriptRoot 'monitor_data.jsonl'
$HtmlFile = Join-Path $PSScriptRoot 'dashboard.html'
$Interval = 2            # seconds between samples
$Keep     = 300          # keep last N samples

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
    # ---------  NEW DASHBOARD TEMPLATE  ---------
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
  --bg:#f6f8fa; --card:#fff; --text:#111; --muted:#6b7280; --accent:#0a84ff;
  --cpu:#ff6b6b; --ram:#6bc1ff; --disk:#8ce99a; --net:#ffd43b; --kill:#ff4d4d;
  --shadow:0 6px 18px rgba(15,23,42,.08);
  --radius:10px; --font:"Segoe UI",Roboto,Arial,sans-serif;
  --resize-h:10px; --resize-w:10px;
}
/*  DARK THEME  */
@media (prefers-color-scheme:dark){
  :root{ --bg:#0d1117; --card:#161b22; --text:#e6edf3; --muted:#8b949e; }
}
[data-theme="dark"]{ --bg:#0d1117; --card:#161b22; --text:#e6edf3; --muted:#8b949e; }
[data-theme="light"]{ --bg:#f6f8fa; --card:#fff; --text:#111; --muted:#6b7280; }

/*  GLOBAL  */
*{box-sizing:border-box;font-family:var(--font);}
body{background:var(--bg);color:var(--text);margin:0;padding:18px;}
.container{max-width:1400px;margin:0 auto;}
button,input,select{background:var(--card);color:var(--text);border:1px solid var(--muted);border-radius:6px;padding:6px 10px;font-size:13px;}
button{cursor:pointer}button:hover{border-color:var(--accent);}
input[type="datetime-local"]{width:100%;max-width:180px;}

/*  HEADER  */
.header{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:14px;flex-wrap:wrap;}
.title{display:flex;align-items:center;gap:12px;}
h1{font-size:22px;margin:0}
.controls{display:flex;gap:8px;align-items:center;flex-wrap:wrap;}

/*  CARDS  */
.card{background:var(--card);padding:14px;border-radius:var(--radius);box-shadow:var(--shadow);position:relative;overflow:hidden;resize:block;}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:14px;}
.card h3{margin:0 0 8px;font-size:17px;font-weight:600;}
.resize{position:absolute;bottom:0;right:0;width:var(--resize-w);height:var(--resize-h);cursor:nw-resize;background:linear-gradient(135deg,transparent 40%,var(--muted) 100%);opacity:.25;transition:opacity .2s}
.card:hover .resize{opacity:.6}

/*  CHART WRAPPER  */
.canvasWrap{width:100%;height:200px;background:linear-gradient(180deg,var(--card),var(--bg));border-radius:6px;padding:8px;box-sizing:border-box;}
canvas{width:100%;height:100%;}

/*  TABLES  */
.tableWrap{max-height:320px;overflow:auto;border:1px solid var(--muted);border-radius:6px;padding:6px;}
table{width:100%;border-collapse:collapse;font-size:13px;}
th,td{padding:6px;border-bottom:1px solid var(--muted);text-align:center;}
th{position:sticky;top:0;background:var(--bg);}

/*  FILTER BAR  */
.filter-bar{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-bottom:14px;}
.filter-bar label{font-size:13px;color:var(--muted);}
.quick-btns{display:flex;gap:6px;}
.quick-btns button{font-size:12px;padding:4px 8px;}

/*  KILL CARD  */
.kill-row{display:flex;align-items:center;gap:10px;margin-top:8px;}
.kill-row button{background:var(--kill);color:#fff;border:none;}
.kill-row button:hover{background:#ff1a1a;}

/*  FOOTER  */
footer{margin-top:14px;text-align:right;color:var(--muted);font-size:12px;}
</style>
</head>
<body>
<div class="container">

  <!--  HEADER  -->
  <div class="header">
    <div class="title">
      <h1>Local PC Monitor</h1>
      <div class="small" id="updated">Updated: {{UPDATED}}</div>
    </div>
    <div class="controls">
      <button id="themeToggle">🌗</button>
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
      <h3>CPU %</h3>
      <div class="canvasWrap"><canvas id="cpuCanvas"></canvas></div>
      <div class="resize"></div>
    </div>
    <div class="card" id="ramCard">
      <h3>Memory %</h3>
      <div class="canvasWrap"><canvas id="ramCanvas"></canvas></div>
      <div class="resize"></div>
    </div>
    <div class="card" id="diskCard">
      <h3>Disk free %</h3>
      <div class="canvasWrap"><canvas id="diskCanvas"></canvas></div>
      <div class="resize"></div>
    </div>
    <div class="card" id="netCard">
      <h3>Network bytes</h3>
      <div class="canvasWrap"><canvas id="netCanvas"></canvas></div>
      <div class="resize"></div>
    </div>

    <!--  NEW: KILL CARD  -->
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
  <div class="card" style="margin-top:14px">
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
const themeBtn = document.getElementById('themeToggle');
function applyTheme(){
  const m = localStorage.theme || (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  document.documentElement.setAttribute('data-theme',m);
}
applyTheme();
themeBtn.onclick = () => {
  const flip = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
  localStorage.theme = flip;
  applyTheme();
};

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
      // show PID of monitor.ps1
      showMonitorPID();
    })
    .catch(err=>{ document.getElementById('status').textContent = 'Error loading data'; });
}
document.getElementById('refresh').onclick = fetchLines;
document.getElementById('autoRefresh').onchange = e => autoRefresh = e.target.checked;

/* ----------  KILL MONITOR  ---------- */
function showMonitorPID(){
  // ask the server for the PID that serve.ps1 exposes via /pid endpoint
  fetch('./pid?_='+Date.now())
    .then(r=>r.text())
    .then(txt=>{ document.getElementById('monPID').textContent = txt.trim(); })
    .catch(()=>{ document.getElementById('monPID').textContent = '??'; });
}
function killMonitor(){
  const pid = document.getElementById('monPID').textContent;
  if(!pid || pid==='--' || pid==='??') return;
  // call the kill endpoint (serve.ps1 will return 200 with empty body)
  fetch('./kill?pid='+pid,{method:'POST'}).then(()=>{
    // mark killed
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
  if(!vals.length){ ctx.fillStyle = '#999'; ctx.font = `${12*dpr}px sans-serif`; ctx.fillText('No data',10*dpr,20*dpr); return;}

  const min = Math.min(...vals), max = Math.max(...vals);
  const pad = 12*dpr, plotW = w - 2*pad, plotH = h - 2*pad;

  // grid
  ctx.strokeStyle = 'rgba(0,0,0,.06)';
  for(let i=0;i<=4;i++){ const y = pad + (plotH/4)*i; ctx.beginPath(); ctx.moveTo(pad,y); ctx.lineTo(pad+plotW,y); ctx.stroke(); }
  // area
  ctx.beginPath();
  vals.forEach((v,i)=>{
    const x = pad + (i/(vals.length-1))*plotW;
    const y = pad + (1 - (v-min)/Math.max(0.0001,max-min))*plotH;
    if(i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
  });
  ctx.lineTo(pad+plotW, pad+plotH); ctx.lineTo(pad, pad+plotH); ctx.closePath();
  const grad = ctx.createLinearGradient(0,pad,0,pad+plotH);
  grad.addColorStop(0, hexToRgba(color,0.25));
  grad.addColorStop(1, hexToRgba(color,0.02));
  ctx.fillStyle = grad; ctx.fill();
  // line
  ctx.beginPath();
  vals.forEach((v,i)=>{
    const x = pad + (i/(vals.length-1))*plotW;
    const y = pad + (1 - (v-min)/Math.max(0.0001,max-min))*plotH;
    if(i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
  });
  ctx.strokeStyle = color; ctx.lineWidth = 2*dpr; ctx.stroke();
  // label
  ctx.fillStyle = '#555';
  ctx.font = `${12*dpr}px sans-serif`;
  ctx.fillText(`${label}  (min:${round(min)} max:${round(max)})`, pad, 12*dpr);
}

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