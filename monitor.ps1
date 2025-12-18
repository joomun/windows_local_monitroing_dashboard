# monitor.ps1
# Samples system metrics periodically, appends JSON lines to monitor_data.jsonl
# and regenerates dashboard.html (self-contained view).

$DataFile = Join-Path $PSScriptRoot 'monitor_data.jsonl'
$HtmlFile = Join-Path $PSScriptRoot 'dashboard.html'
$Interval = 2            # seconds between samples
$Keep = 300              # keep last N samples

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

    # Network bytes (sum of adapters since boot) - this shows cumulative; you can derive delta if needed.
    try {
        $netStats = Get-NetAdapterStatistics | Measure-Object -Property ReceivedBytes,SentBytes -Sum
        $netBytes = ($netStats.SumReceivedBytes + $netStats.SumSentBytes)
    } catch {
        # fallback: 0 if cmdlet not available
        $netBytes = 0
    }

    $obj = [pscustomobject]@{
        Time = $time
        CPU = $cpu
        MemoryPercent = $memPercent
        DiskFreePercent = $diskFreePercent
        NetworkBytes = $netBytes
    }

    $obj | ConvertTo-Json -Compress | Out-File -FilePath $DataFile -Append -Encoding utf8

    # Trim file to last $Keep lines to avoid unbounded growth
    $lines = Get-Content $DataFile -Tail $Keep
    $lines | Set-Content $DataFile -Encoding utf8

    # Build an array from lines and emit compact JSON for embedding in HTML
    # (replaced embedding with dynamic-loading HTML that fetches the JSONL file and paginates client-side)
    $dataFileName = Split-Path $DataFile -Leaf
    $updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    # Use single-quoted here-string to avoid PowerShell expanding JS template literals (${...})
    $html = @'
<!doctype html>
<html>
<head>
<meta charset='utf-8'>
<title>Local PC Monitor</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{
  --bg:#f6f8fa; --card:#fff; --muted:#6b7280; --accent:#0a84ff; --cpu:#ff6b6b; --ram:#6bc1ff;
  --shadow: 0 6px 18px rgba(15,23,42,0.08);
  font-family: "Segoe UI", Roboto, Arial, sans-serif;
}
body{background:var(--bg);margin:0;padding:18px;color:#111}
.container{max-width:1200px;margin:0 auto}
.header{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:14px}
.title{display:flex;align-items:center;gap:12px}
h1{font-size:20px;margin:0}
.controls{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.card{background:var(--card);padding:12px;border-radius:10px;box-shadow:var(--shadow);margin-bottom:12px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}
@media (max-width:800px){ .grid{grid-template-columns:1fr} }
.sectionHeader{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:8px}
.btn{background:transparent;border:1px solid #e6e9ee;padding:6px 10px;border-radius:6px;cursor:pointer}
.btn:active{transform:translateY(1px)}
.small{font-size:12px;color:var(--muted)}
.select, input[type="number"]{padding:6px;border-radius:6px;border:1px solid #e6e9ee}
.canvasWrap{width:100%;height:180px;background:linear-gradient(180deg,#fff, #fbfdff);border-radius:6px;padding:8px;box-sizing:border-box}
.tableWrap{max-height:320px;overflow:auto;background:#fff;border-radius:6px;padding:6px;border:1px solid #eef2f6}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{padding:6px;border-bottom:1px solid #f0f2f5;text-align:center}
th{background:#fbfcfe;color:#444;position:sticky;top:0}
.legend{display:flex;gap:8px;align-items:center;font-size:13px}
.legend .dot{width:10px;height:10px;border-radius:50%}
.status{color:var(--muted);font-size:13px}
.pager{display:flex;gap:6px;align-items:center}
footer{margin-top:14px;text-align:right;color:var(--muted);font-size:12px}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="title">
      <h1>Local PC Monitor</h1>
      <div class="small" id="updated">Updated: {{UPDATED}}</div>
    </div>
    <div class="controls">
      <label class="small">Page size
        <select id="pageSize" class="select">
          <option>25</option><option>50</option><option selected>100</option><option>200</option>
        </select>
      </label>
      <div class="pager">
        <button id="prev" class="btn">Prev</button>
        <button id="next" class="btn">Next</button>
        <span class="small">Page <input id="pageInput" type="number" min="1" value="1" style="width:56px"> / <span id="pageCount">0</span></span>
      </div>
      <label class="small"><input id="autoRefresh" type="checkbox" checked> Auto</label>
      <button id="refresh" class="btn">Refresh</button>
      <div id="status" class="status"></div>
    </div>
  </div>

  <div class="grid">
    <!-- CPU section -->
    <div class="card" id="cpuCard">
      <div class="sectionHeader">
        <div style="display:flex;flex-direction:column">
          <strong>CPU</strong>
          <div class="small">CPU % (average)</div>
        </div>
        <div style="display:flex;align-items:center;gap:8px">
          <div class="legend"><div class="dot" style="background:var(--cpu)"></div><div class="small">CPU</div></div>
          <label class="small">View:
            <select id="cpuView" class="select">
              <option value="graph" selected>Graph</option>
              <option value="data">Data</option>
            </select>
          </label>
        </div>
      </div>

      <div id="cpuGraphArea" class="canvasWrap" style="display:block">
        <canvas id="cpuCanvas" width="800" height="160"></canvas>
      </div>
      <div id="cpuDataArea" class="tableWrap" style="display:none"></div>
    </div>

    <!-- RAM section -->
    <div class="card" id="ramCard">
      <div class="sectionHeader">
        <div style="display:flex;flex-direction:column">
          <strong>Memory</strong>
          <div class="small">Memory usage %</div>
        </div>
        <div style="display:flex;align-items:center;gap:8px">
          <div class="legend"><div class="dot" style="background:var(--ram)"></div><div class="small">Memory</div></div>
          <label class="small">View:
            <select id="ramView" class="select">
              <option value="graph" selected>Graph</option>
              <option value="data">Data</option>
            </select>
          </label>
        </div>
      </div>

      <div id="ramGraphArea" class="canvasWrap" style="display:block">
        <canvas id="ramCanvas" width="800" height="160"></canvas>
      </div>
      <div id="ramDataArea" class="tableWrap" style="display:none"></div>
    </div>
  </div>

  <div class="card">
    <div style="display:flex;justify-content:space-between;align-items:center">
      <div class="small">Raw sample file: <code>{{DATAFILE}}</code></div>
      <div class="small">Showing <span id="sampleCount">0</span> samples</div>
    </div>
  </div>

  <footer class="small">Open via local server (see [monitor.bat](http://_vscodecontentref_/2) -> Open HTML view) to avoid local file fetch restrictions.</footer>
</div>

<script>
const dataFile = "./{{DATAFILE}}";
let lines = [];
let page = 1;
let pageSize = parseInt(document.getElementById('pageSize').value,10);
let autoRefresh = document.getElementById('autoRefresh').checked;
let refreshInterval = 4000;

function parseLines(text){
  const raw = text.split(/\r?\n/);
  return raw.filter(l => l && l.trim() && !l.trim().startsWith('//'));
}

function fetchLines(){
  document.getElementById('status').textContent = 'Loading...';
  return fetch(dataFile + '?_=' + Date.now()).then(r => {
    if (!r.ok) throw new Error('Could not load data file');
    return r.text();
  }).then(t => {
    lines = parseLines(t);
    document.getElementById('status').textContent = '';
    document.getElementById('updated').textContent = 'Updated: ' + (new Date()).toISOString().replace('T',' ').split('.')[0];
    document.getElementById('sampleCount').textContent = lines.length;
    updatePager();
    renderAll();
  }).catch(err=>{
    document.getElementById('status').textContent = 'Error loading data';
    console.error(err);
  });
}

function updatePager(){
  pageSize = parseInt(document.getElementById('pageSize').value,10) || 100;
  const pageCount = Math.max(1, Math.ceil(lines.length / pageSize));
  if (page > pageCount) page = pageCount;
  document.getElementById('pageCount').textContent = pageCount;
  document.getElementById('pageInput').value = page;
}

function slicePage(){
  const start = (page-1)*pageSize;
  const end = Math.min(lines.length, start + pageSize);
  return lines.slice(start,end);
}

function renderAll(){
  renderCharts();
  renderDataTables();
}

function parseJSONSafe(line){
  try { return JSON.parse(line); } catch(e){ return null; }
}

function renderCharts(){
  // use last N samples from entire file (not just page) for charts for smoother view
  const lastN = Math.min(lines.length, Math.max(50, pageSize));
  const pageLines = lines.slice(Math.max(0, lines.length - lastN));
  const cpuVals = [], memVals = [], times = [];
  for (let i=0;i<pageLines.length;i++){
    const d = parseJSONSafe(pageLines[i]); if (!d) continue;
    cpuVals.push(isFinite(Number(d.CPU)) ? Number(d.CPU) : null);
    memVals.push(isFinite(Number(d.MemoryPercent)) ? Number(d.MemoryPercent) : null);
    times.push(d.Time || '');
  }
  drawChart(document.getElementById('cpuCanvas'), cpuVals, times, 'CPU %', '#ff6b6b');
  drawChart(document.getElementById('ramCanvas'), memVals, times, 'Memory %', '#6bc1ff');
}

function drawChart(canvas, values, labels, labelText, strokeStyle){
  const ctx = canvas.getContext('2d');
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth * dpr;
  const h = canvas.clientHeight * dpr;
  canvas.width = w; canvas.height = h;
  ctx.clearRect(0,0,w,h);
  const vals = values.filter(v => v !== null && v !== undefined);
  if (!vals.length) {
    ctx.fillStyle = '#999';
    ctx.font = `${12*dpr}px sans-serif`;
    ctx.fillText('No data', 10*dpr, 20*dpr);
    return;
  }
  const max = Math.max(...vals), min = Math.min(...vals);
  const padding = 12*dpr;
  const plotW = w - padding*2;
  const plotH = h - padding*2;
  ctx.save();
  // grid lines
  ctx.strokeStyle = 'rgba(0,0,0,0.06)';
  ctx.lineWidth = 1;
  for (let i=0;i<=4;i++){
    const y = padding + (plotH/4)*i;
    ctx.beginPath(); ctx.moveTo(padding, y); ctx.lineTo(padding+plotW, y); ctx.stroke();
  }
  // polyline
  ctx.beginPath();
  for (let i=0,pi=0;i<values.length;i++){
    const v = values[i];
    if (v===null || v===undefined) continue;
    const x = padding + (pi/(values.length-1))*plotW;
    const y = padding + (1 - (v - min) / Math.max(0.0001, (max-min)) ) * plotH;
    if (pi===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
    pi++;
  }
  ctx.strokeStyle = strokeStyle;
  ctx.lineWidth = 2 * dpr;
  ctx.stroke();

  // area fill
  ctx.lineTo(padding+plotW, padding+plotH);
  ctx.lineTo(padding, padding+plotH);
  ctx.closePath();
  const grad = ctx.createLinearGradient(0,padding,0,padding+plotH);
  grad.addColorStop(0, hexToRgba(strokeStyle,0.18));
  grad.addColorStop(1, hexToRgba(strokeStyle,0.02));
  ctx.fillStyle = grad;
  ctx.fill();

  // labels
  ctx.fillStyle = '#333';
  ctx.font = `${12*dpr}px sans-serif`;
  ctx.fillText(labelText + ' (min:' + round(min) + ' max:' + round(max) + ')', padding, 12*dpr);

  ctx.restore();
}

function round(v){ return Math.round(v*100)/100 }
function hexToRgba(hex, a){
  // simple hex to rgba
  hex = hex.replace('#','');
  const r = parseInt(hex.substring(0,2),16),
        g = parseInt(hex.substring(2,4),16),
        b = parseInt(hex.substring(4,6),16);
  return `rgba(${r},${g},${b},${a})`;
}

function renderDataTables(){
  const pageLines = slicePage();
  // CPU table
  let cpuHtml = '<table><thead><tr><th>Time</th><th>CPU %</th></tr></thead><tbody>';
  for (let i=0;i<pageLines.length;i++){
    const d = parseJSONSafe(pageLines[i]); if (!d) continue;
    cpuHtml += '<tr><td>' + escapeHtml(d.Time||'') + '</td><td>' + (d.CPU ?? '') + '</td></tr>';
  }
  cpuHtml += '</tbody></table>';
  document.getElementById('cpuDataArea').innerHTML = cpuHtml;

  // RAM table
  let ramHtml = '<table><thead><tr><th>Time</th><th>Memory %</th></tr></thead><tbody>';
  for (let i=0;i<pageLines.length;i++){
    const d = parseJSONSafe(pageLines[i]); if (!d) continue;
    ramHtml += '<tr><td>' + escapeHtml(d.Time||'') + '</td><td>' + (d.MemoryPercent ?? '') + '</td></tr>';
  }
  ramHtml += '</tbody></table>';
  document.getElementById('ramDataArea').innerHTML = ramHtml;
}

function escapeHtml(s){
  return String(s).replace(/[&<>"']/g, function(m){
    return {
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#39;'
    }[m];
  });
}
document.getElementById('pageSize').addEventListener('change', ()=>{ updatePager(); renderAll(); });
document.getElementById('prev').addEventListener('click', ()=>{ page = Math.max(1,page-1); updatePager(); renderAll(); });
document.getElementById('next').addEventListener('click', ()=>{ const pc = Math.max(1,Math.ceil(lines.length/pageSize)); page = Math.min(pc,page+1); updatePager(); renderAll(); });
document.getElementById('pageInput').addEventListener('change', ()=>{ let v = parseInt(document.getElementById('pageInput').value,10)||1; const pc = Math.max(1,Math.ceil(lines.length/pageSize)); page = Math.min(Math.max(1,v),pc); updatePager(); renderAll(); });

document.getElementById('refresh').addEventListener('click', ()=>fetchLines());
document.getElementById('autoRefresh').addEventListener('change', (e)=> autoRefresh = e.target.checked);

document.getElementById('cpuView').addEventListener('change',(e)=>{ const v=e.target.value; document.getElementById('cpuGraphArea').style.display = v==='graph'?'block':'none'; document.getElementById('cpuDataArea').style.display = v==='data'?'block':'none'; });
document.getElementById('ramView').addEventListener('change',(e)=>{ const v=e.target.value; document.getElementById('ramGraphArea').style.display = v==='graph'?'block':'none'; document.getElementById('ramDataArea').style.display = v==='data'?'block':'none'; });

setInterval(()=>{ if (autoRefresh) fetchLines(); }, refreshInterval);

// initial load
fetchLines();
</script>
</body>
</html>
'@

    # inject the actual filename and timestamp into the safe single-quoted template
    $html = $html.Replace('{{DATAFILE}}', $dataFileName)
    $html = $html.Replace('{{UPDATED}}', $updated)

    $html | Set-Content $HtmlFile -Encoding utf8

    Start-Sleep -Seconds $Interval
}