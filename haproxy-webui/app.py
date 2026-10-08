#!/usr/bin/env python3
import sys
import os
import json
import socket
import csv
import io
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
import urllib.parse

SOCKET_PATH = '/var/lib/haproxy/stats'
PORT = 9090

def exec_socket(cmd):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(SOCKET_PATH)
        s.sendall((cmd.strip() + "\n").encode('utf-8'))
        resp = b''
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            resp += chunk
        s.close()
        return resp.decode('utf-8', errors='replace')
    except Exception as e:
        return "ERROR: " + str(e)

def get_stats():
    raw = exec_socket("show stat")
    if raw.startswith("ERROR:"):
        return {"error": raw}
    
    lines = [l for l in raw.strip().split('\n') if l]
    if not lines:
        return {"error": "Empty response from socket"}
    
    reader = csv.DictReader(lines)
    records = []
    for row in reader:
        clean_row = {}
        for k, v in row.items():
            if k:
                clean_row[k.strip('# ')] = v
        records.append(clean_row)

    info_raw = exec_socket("show info")
    info = {}
    for line in info_raw.split('\n'):
        if ':' in line:
            k, v = line.split(':', 1)
            info[k.strip()] = v.strip()

    return {"info": info, "stats": records}

def set_server_state(backend, server, state):
    cmd = "set server {}/{} state {}".format(backend, server, state)
    return exec_socket(cmd)

def set_node_all_backends(node_name, state):
    backends = [
        "okd4_http_ingress_traffic_be",
        "okd4_https_ingress_traffic_be",
        "istio_http_ingress_traffic_be",
        "okd4_k8s_api_be",
        "okd4_machine_config_server_be"
    ]
    results = {}
    for be in backends:
        res = set_server_state(be, node_name, state)
        results[be] = res.strip() if res else "OK"
    return results

def set_site_state(site, state):
    mapping = {
        "site-a": ["okd4-worker-1", "okd4-worker-2"],
        "site-b": ["okd4-worker-3", "okd4-worker-4"],
        "all": ["okd4-worker-1", "okd4-worker-2", "okd4-worker-3", "okd4-worker-4"]
    }
    nodes = mapping.get(site, [])
    results = {}
    for n in nodes:
        results[n] = set_node_all_backends(n, state)
    return results

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>HAProxy Metro Stretch Load Balancer Controller</title>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg-base: #0b0f19;
      --bg-card: #131b2e;
      --bg-card-hover: #19233c;
      --border-color: #23304f;
      --text-main: #f1f5f9;
      --text-muted: #94a3b8;
      --accent-blue: #38bdf8;
      --accent-green: #22c55e;
      --accent-yellow: #eab308;
      --accent-red: #ef4444;
      --accent-purple: #a855f7;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Inter', -apple-system, sans-serif;
      background: var(--bg-base);
      color: var(--text-main);
      padding: 24px;
      min-height: 100vh;
    }
    .container { max-width: 1350px; margin: 0 auto; }
    
    /* Header */
    header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding-bottom: 20px;
      border-bottom: 1px solid var(--border-color);
      margin-bottom: 24px;
      flex-wrap: wrap;
      gap: 16px;
    }
    .logo-group h1 {
      font-size: 24px;
      font-weight: 700;
      letter-spacing: -0.5px;
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .badge-live {
      background: rgba(34, 197, 94, 0.15);
      color: var(--accent-green);
      font-size: 12px;
      padding: 4px 10px;
      border-radius: 9999px;
      font-weight: 600;
      border: 1px solid rgba(34, 197, 94, 0.3);
      display: inline-flex;
      align-items: center;
      gap: 6px;
    }
    .badge-live::before {
      content: '';
      width: 8px;
      height: 8px;
      background: var(--accent-green);
      border-radius: 50%;
      box-shadow: 0 0 8px var(--accent-green);
    }
    .subtext {
      color: var(--text-muted);
      font-size: 14px;
      margin-top: 4px;
    }
    .quick-links a {
      color: var(--accent-blue);
      text-decoration: none;
      font-size: 13px;
      background: var(--bg-card);
      padding: 8px 14px;
      border-radius: 8px;
      border: 1px solid var(--border-color);
      transition: all 0.2s;
    }
    .quick-links a:hover {
      background: var(--bg-card-hover);
      border-color: var(--accent-blue);
    }

    /* Fast Action Ribbon */
    .action-ribbon {
      background: linear-gradient(135deg, #1e293b, #0f172a);
      border: 1px solid var(--border-color);
      border-radius: 12px;
      padding: 18px 24px;
      margin-bottom: 28px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 16px;
      box-shadow: 0 4px 20px rgba(0, 0, 0, 0.3);
    }
    .ribbon-title {
      font-size: 16px;
      font-weight: 600;
    }
    .ribbon-sub { font-size: 13px; color: var(--text-muted); }
    .btn-group { display: flex; gap: 10px; flex-wrap: wrap; }
    
    /* Buttons */
    button {
      font-family: inherit;
      font-size: 13px;
      font-weight: 600;
      padding: 8px 16px;
      border-radius: 8px;
      border: none;
      cursor: pointer;
      transition: all 0.15s ease;
      display: inline-flex;
      align-items: center;
      gap: 6px;
    }
    button:active { transform: scale(0.97); }
    .btn-green { background: #15803d; color: #fff; }
    .btn-green:hover { background: #16a34a; box-shadow: 0 0 12px rgba(34, 197, 94, 0.4); }
    .btn-red { background: #b91c1c; color: #fff; }
    .btn-red:hover { background: #dc2626; box-shadow: 0 0 12px rgba(239, 68, 68, 0.4); }
    .btn-yellow { background: #a16207; color: #fff; }
    .btn-yellow:hover { background: #ca8a04; box-shadow: 0 0 12px rgba(234, 179, 8, 0.4); }
    .btn-blue { background: #1d4ed8; color: #fff; }
    .btn-blue:hover { background: #2563eb; }
    .btn-outline {
      background: transparent;
      border: 1px solid var(--border-color);
      color: var(--text-main);
    }
    .btn-outline:hover { background: var(--bg-card-hover); border-color: var(--text-muted); }

    /* Stats Grid */
    .stats-overview {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 16px;
      margin-bottom: 28px;
    }
    .stat-card {
      background: var(--bg-card);
      border: 1px solid var(--border-color);
      border-radius: 10px;
      padding: 16px;
    }
    .stat-card .label { font-size: 12px; color: var(--text-muted); text-transform: uppercase; font-weight: 600; }
    .stat-card .value { font-size: 22px; font-weight: 700; margin-top: 6px; font-family: 'JetBrains Mono', monospace; }

    /* Zone Grid */
    .zones-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(600px, 1fr));
      gap: 24px;
      margin-bottom: 28px;
    }
    @media (max-width: 768px) {
      .zones-grid { grid-template-columns: 1fr; }
    }
    .zone-box {
      background: var(--bg-card);
      border: 1px solid var(--border-color);
      border-radius: 12px;
      padding: 20px;
    }
    .zone-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 16px;
      padding-bottom: 12px;
      border-bottom: 1px solid var(--border-color);
    }
    .zone-title {
      font-size: 16px;
      font-weight: 700;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .node-item {
      background: #0f1523;
      border: 1px solid #1e2840;
      border-radius: 10px;
      padding: 16px;
      margin-bottom: 12px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 14px;
    }
    .node-info .name {
      font-size: 15px;
      font-weight: 600;
      font-family: 'JetBrains Mono', monospace;
    }
    .node-info .meta {
      font-size: 12px;
      color: var(--text-muted);
      margin-top: 4px;
      display: flex;
      gap: 12px;
    }
    .status-pill {
      font-size: 11px;
      padding: 3px 8px;
      border-radius: 6px;
      font-weight: 700;
      text-transform: uppercase;
      font-family: 'JetBrains Mono', monospace;
    }
    .pill-UP { background: rgba(34, 197, 94, 0.2); color: #4ade80; border: 1px solid #22c55e; }
    .pill-MAINT { background: rgba(234, 179, 8, 0.2); color: #facc15; border: 1px solid #eab308; }
    .pill-DRAIN { background: rgba(56, 189, 248, 0.2); color: #38bdf8; border: 1px solid #0284c7; }
    .pill-DOWN { background: rgba(239, 68, 68, 0.2); color: #f87171; border: 1px solid #ef4444; }

    /* Tables */
    .table-container {
      background: var(--bg-card);
      border: 1px solid var(--border-color);
      border-radius: 12px;
      padding: 20px;
      margin-bottom: 28px;
      overflow-x: auto;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
    }
    th {
      text-align: left;
      padding: 10px 12px;
      background: #0f1523;
      color: var(--text-muted);
      font-weight: 600;
      border-bottom: 1px solid var(--border-color);
    }
    td {
      padding: 12px;
      border-bottom: 1px solid #1a233a;
      font-family: 'JetBrains Mono', monospace;
    }
    tr:hover td { background: var(--bg-card-hover); }

    /* Toast */
    #toast {
      position: fixed;
      bottom: 24px;
      right: 24px;
      background: #1e293b;
      color: #fff;
      padding: 12px 20px;
      border-radius: 8px;
      border: 1px solid var(--accent-blue);
      box-shadow: 0 4px 16px rgba(0,0,0,0.5);
      display: none;
      z-index: 1000;
      font-weight: 500;
      font-size: 14px;
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="logo-group">
        <h1>
          <span>🛡️ OpenShift Metro HAProxy Web Controller</span>
          <span class="badge-live" id="status-badge">ONLINE</span>
        </h1>
        <div class="subtext">Proxmox LXC 105 (<code>10.10.10.30</code>) &bull; Metro Stretch Cluster Locality Controller</div>
      </div>
      <div class="quick-links">
        <a href="http://10.10.10.30:9000/" target="_blank">📊 HAProxy Native Stats</a>
        <a href="https://kiali-istio-system.apps.okd.dorneean.wan" target="_blank">🕸️ Kiali Console</a>
        <a href="https://shared-edge-route-istio-system.apps.okd.dorneean.wan" target="_blank">🌐 App Ingress</a>
      </div>
    </header>

    <!-- Fast Action Ribbon -->
    <div class="action-ribbon">
      <div>
        <div class="ribbon-title">⚡ Rapid Metro Disaster & Locality Controls</div>
        <div class="ribbon-sub">Disable or enable entire zones across HTTP & HTTPS ingress backends with a single click.</div>
      </div>
      <div class="btn-group">
        <button class="btn-red" onclick="toggleSite('site-a', 'maint')">🔴 Disable Site A (Force Site B)</button>
        <button class="btn-yellow" onclick="toggleSite('site-b', 'maint')">🟡 Disable Site B</button>
        <button class="btn-green" onclick="toggleSite('all', 'ready')">🟢 Restore All Nodes (Active-Active)</button>
      </div>
    </div>

    <!-- Stats Overview -->
    <div class="stats-overview">
      <div class="stat-card">
        <div class="label">Active Connections</div>
        <div class="value" id="stat-scur" style="color: var(--accent-blue);">-</div>
      </div>
      <div class="stat-card">
        <div class="label">Total Sessions</div>
        <div class="value" id="stat-stot">-</div>
      </div>
      <div class="stat-card">
        <div class="label">Uptime</div>
        <div class="value" id="stat-uptime" style="font-size: 16px; color: var(--text-muted);">-</div>
      </div>
      <div class="stat-card">
        <div class="label">Auto-Refresh</div>
        <div class="value" style="color: var(--accent-green); font-size: 16px;">Every 2s (Live)</div>
      </div>
    </div>

    <!-- Zones Grid -->
    <div class="zones-grid">
      <!-- Site A -->
      <div class="zone-box">
        <div class="zone-header">
          <div class="zone-title">
            <span style="color: var(--accent-green);">🏢 Site A (Primary Metro Zone)</span>
          </div>
          <div class="btn-group">
            <button class="btn-outline" style="padding:4px 10px; font-size:12px;" onclick="toggleSite('site-a', 'maint')">Disable Zone</button>
            <button class="btn-green" style="padding:4px 10px; font-size:12px;" onclick="toggleSite('site-a', 'ready')">Enable Zone</button>
          </div>
        </div>

        <div class="node-item" id="node-okd4-worker-1">
          <div class="node-info">
            <div class="name">okd4-worker-1 <span class="status-pill pill-UP" id="pill-okd4-worker-1">UP</span></div>
            <div class="meta"><span>IP: 10.10.10.53</span> <span>Subzone: site-a</span></div>
          </div>
          <div class="btn-group">
            <button class="btn-green" onclick="setNodeState('okd4-worker-1', 'ready')">Ready</button>
            <button class="btn-red" onclick="setNodeState('okd4-worker-1', 'maint')">Disable</button>
            <button class="btn-blue" onclick="setNodeState('okd4-worker-1', 'drain')">Drain</button>
          </div>
        </div>

        <div class="node-item" id="node-okd4-worker-2">
          <div class="node-info">
            <div class="name">okd4-worker-2 <span class="status-pill pill-UP" id="pill-okd4-worker-2">UP</span></div>
            <div class="meta"><span>IP: 10.10.10.54</span> <span>Subzone: site-a</span></div>
          </div>
          <div class="btn-group">
            <button class="btn-green" onclick="setNodeState('okd4-worker-2', 'ready')">Ready</button>
            <button class="btn-red" onclick="setNodeState('okd4-worker-2', 'maint')">Disable</button>
            <button class="btn-blue" onclick="setNodeState('okd4-worker-2', 'drain')">Drain</button>
          </div>
        </div>
      </div>

      <!-- Site B -->
      <div class="zone-box">
        <div class="zone-header">
          <div class="zone-title">
            <span style="color: var(--accent-yellow);">🏢 Site B (Standby / Survivor Zone)</span>
          </div>
          <div class="btn-group">
            <button class="btn-outline" style="padding:4px 10px; font-size:12px;" onclick="toggleSite('site-b', 'maint')">Disable Zone</button>
            <button class="btn-green" style="padding:4px 10px; font-size:12px;" onclick="toggleSite('site-b', 'ready')">Enable Zone</button>
          </div>
        </div>

        <div class="node-item" id="node-okd4-worker-3">
          <div class="node-info">
            <div class="name">okd4-worker-3 <span class="status-pill pill-UP" id="pill-okd4-worker-3">UP</span></div>
            <div class="meta"><span>IP: 10.10.10.55</span> <span>Subzone: site-b</span></div>
          </div>
          <div class="btn-group">
            <button class="btn-green" onclick="setNodeState('okd4-worker-3', 'ready')">Ready</button>
            <button class="btn-red" onclick="setNodeState('okd4-worker-3', 'maint')">Disable</button>
            <button class="btn-blue" onclick="setNodeState('okd4-worker-3', 'drain')">Drain</button>
          </div>
        </div>

        <div class="node-item" id="node-okd4-worker-4">
          <div class="node-info">
            <div class="name">okd4-worker-4 <span class="status-pill pill-UP" id="pill-okd4-worker-4">UP</span></div>
            <div class="meta"><span>IP: 10.10.10.56</span> <span>Subzone: site-b</span></div>
          </div>
          <div class="btn-group">
            <button class="btn-green" onclick="setNodeState('okd4-worker-4', 'ready')">Ready</button>
            <button class="btn-red" onclick="setNodeState('okd4-worker-4', 'maint')">Disable</button>
            <button class="btn-blue" onclick="setNodeState('okd4-worker-4', 'drain')">Drain</button>
          </div>
        </div>
      </div>
    </div>

    <!-- Backend Details Table -->
    <div class="table-container">
      <div style="font-size: 16px; font-weight: 700; margin-bottom: 12px;">🔍 Backend Service Detail & Live Metrics</div>
      <table>
        <thead>
          <tr>
            <th>Backend</th>
            <th>Server Node</th>
            <th>Status</th>
            <th>Cur / Max Sess</th>
            <th>Total Req</th>
            <th>Check Status</th>
            <th>Action</th>
          </tr>
        </thead>
        <tbody id="backend-table-body">
          <tr><td colspan="7" style="text-align:center; color: var(--text-muted);">Loading HAProxy metrics...</td></tr>
        </tbody>
      </table>
    </div>
  </div>

  <div id="toast">Action executed</div>

  <script>
    function showToast(msg) {
      const t = document.getElementById('toast');
      t.innerText = msg;
      t.style.display = 'block';
      setTimeout(() => { t.style.display = 'none'; }, 3000);
    }

    async function fetchStats() {
      try {
        const res = await fetch('/api/stats');
        const data = await res.json();
        if (data.error) return;

        if (data.info) {
          document.getElementById('stat-uptime').innerText = data.info['Uptime'] || '-';
        }

        let totalScur = 0;
        let totalStot = 0;
        let tbody = '';
        const nodeStatuses = {};

        data.stats.forEach(s => {
          if (s.svname === 'FRONTEND' || s.svname === 'BACKEND') {
            if (s.svname === 'FRONTEND') {
              totalScur += parseInt(s.scur || 0);
              totalStot += parseInt(s.stot || 0);
            }
            return;
          }

          if (s.pxname.includes('ingress')) {
            nodeStatuses[s.svname] = s.status;
          }

          let pillClass = 'pill-UP';
          if (s.status.includes('MAINT')) pillClass = 'pill-MAINT';
          else if (s.status.includes('DRAIN')) pillClass = 'pill-DRAIN';
          else if (s.status.includes('DOWN')) pillClass = 'pill-DOWN';

          tbody += `
            <tr>
              <td><strong>${s.pxname}</strong></td>
              <td>${s.svname}</td>
              <td><span class="status-pill ${pillClass}">${s.status}</span></td>
              <td>${s.scur || 0} / ${s.smax || 0}</td>
              <td>${s.stot || 0}</td>
              <td>${s.check_status || 'OK'}</td>
              <td>
                <button class="btn-outline" style="padding:3px 8px; font-size:11px;" onclick="setDirectServer('${s.pxname}', '${s.svname}', 'ready')">Ready</button>
                <button class="btn-outline" style="padding:3px 8px; font-size:11px; color:#ef4444;" onclick="setDirectServer('${s.pxname}', '${s.svname}', 'maint')">Maint</button>
                <button class="btn-outline" style="padding:3px 8px; font-size:11px; color:#38bdf8;" onclick="setDirectServer('${s.pxname}', '${s.svname}', 'drain')">Drain</button>
              </td>
            </tr>
          `;
        });

        document.getElementById('stat-scur').innerText = totalScur;
        document.getElementById('stat-stot').innerText = totalStot;
        document.getElementById('backend-table-body').innerHTML = tbody;

        ['okd4-worker-1', 'okd4-worker-2', 'okd4-worker-3', 'okd4-worker-4'].forEach(n => {
          const st = nodeStatuses[n] || 'UP';
          const pill = document.getElementById('pill-' + n);
          if (pill) {
            pill.innerText = st;
            pill.className = 'status-pill ' + (st.includes('MAINT') ? 'pill-MAINT' : (st.includes('DRAIN') ? 'pill-DRAIN' : (st.includes('DOWN') ? 'pill-DOWN' : 'pill-UP')));
          }
        });

      } catch (e) {
        console.error('Fetch error:', e);
      }
    }

    async function setNodeState(node, state) {
      showToast('Setting ' + node + ' to ' + state.toUpperCase() + '...');
      await fetch('/api/node/state', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({node: node, state: state})
      });
      fetchStats();
    }

    async function setDirectServer(backend, server, state) {
      showToast('Setting ' + backend + '/' + server + ' to ' + state.toUpperCase() + '...');
      await fetch('/api/server/state', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({backend: backend, server: server, state: state})
      });
      fetchStats();
    }

    async function toggleSite(site, state) {
      showToast('Setting ' + site.toUpperCase() + ' to ' + state.toUpperCase() + '...');
      await fetch('/api/site/action', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({site: site, action: state})
      });
      fetchStats();
    }

    setInterval(fetchStats, 2000);
    fetchStats();
  </script>
</body>
</html>
"""

class RequestHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_HEAD(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/' or parsed.path == '/index.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(HTML_TEMPLATE.encode('utf-8'))
        elif parsed.path == '/api/stats':
            data = get_stats()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(data).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        payload = {}
        try:
            payload = json.loads(body.decode('utf-8'))
        except:
            pass

        if parsed.path == '/api/server/state':
            backend = payload.get('backend')
            server = payload.get('server')
            state = payload.get('state', 'ready')
            res = set_server_state(backend, server, state)
            self.send_json({"status": "ok", "response": res})
        elif parsed.path == '/api/node/state':
            node = payload.get('node')
            state = payload.get('state', 'ready')
            res = set_node_all_backends(node, state)
            self.send_json({"status": "ok", "response": res})
        elif parsed.path == '/api/site/action':
            site = payload.get('site')
            action = payload.get('action', 'ready')
            res = set_site_state(site, action)
            self.send_json({"status": "ok", "response": res})
        else:
            self.send_response(404)
            self.end_headers()

    def send_json(self, data):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', PORT), RequestHandler)
    print("HAProxy Web UI started on http://0.0.0.0:" + str(PORT))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
