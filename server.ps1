Import-Module NetTCPIP -ErrorAction SilentlyContinue

$port = [int]$env:TARGET_PORT
if ($port -le 0) { $port = 8080 }

# Verificación de escuchas previas (excluyendo PID 4 de fallo crítico)
$portActive = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -ne 4 }
if ($portActive) {
    Write-Host "[!] El puerto $port está ocupado por un proceso de usuario (PID $($portActive.OwningProcess))." -ForegroundColor Red
    return
}

$listener = New-Object System.Net.HttpListener

# Uso preferente de localhost/127.0.0.1 para evitar acoplamientos rígidos en HTTP.sys (PID 4)
$listener.Prefixes.Add("http://localhost:${port}/")
$listener.Prefixes.Add("http://127.0.0.1:${port}/")

try {
    $listener.Start()
} catch {
    $listener.Prefixes.Clear()
    $listener.Prefixes.Add("http://+:${port}/")
    try {
        $listener.Start()
    } catch {
        Write-Host "[!] Error al iniciar HttpListener en puerto ${port} - $_" -ForegroundColor Red
        return
    }
}

$checkConn = Test-NetConnection -ComputerName "127.0.0.1" -Port $port -WarningAction SilentlyContinue
if ($checkConn.TcpTestSucceeded) {
    $portStatus = "ABIERTO Y ESCUCHANDO"
    $statusColor = "Green"
} else {
    $portStatus = "NO RESPONDE"
    $statusColor = "Red"
}

Write-Host ""
Write-Host "===================================================" -ForegroundColor Green
Write-Host " Servidor Web activo" -ForegroundColor Green
Write-Host " Verificacion de puerto ${port} : ${portStatus}" -ForegroundColor $statusColor
Write-Host "===================================================" -ForegroundColor Green
Write-Host " Abre tu navegador e ingresa manualmente a:" -ForegroundColor Cyan
Write-Host "   http://localhost:${port}  o  http://127.0.0.1:${port}" -ForegroundColor Cyan
Write-Host ""
Write-Host " Presiona [Q] o [X] en esta consola para CERRAR." -ForegroundColor Yellow
Write-Host "===================================================" -ForegroundColor Green
Write-Host ""

while ([Console]::KeyAvailable) {
    [Console]::ReadKey($true) | Out-Null
}

$ipFilePath = Join-Path $PSScriptRoot "ips.json"
if (-not (Test-Path $ipFilePath)) {
    @("8.8.8.8", "1.1.1.1") | ConvertTo-Json | Set-Content -Path $ipFilePath -Encoding UTF8
}

$global:CurrentIfaceName = ""
$global:CurrentIfaceIndex = -1
$global:RxMbps = 0.0
$global:LinkSpeed = "N/A"
$global:IsConnected = $false
$global:HasInternet = $false
$global:IsIdentifying = $false
$global:IdentifyUntil = $null
$global:PingTimeoutEpisode = $false
$global:PingTTL = -1
$global:InternetCheckAt = [DateTime]::MinValue
$global:PrevBytes = 0
$global:PrevTime = [DateTime]::Now

$global:PingTarget = "8.8.8.8"
$global:PingTimeMs = -1
$global:PingJob = $null


function Test-InterfaceInternet {
    param([System.Net.NetworkInformation.NetworkInterface]$Nic)

    if (-not $Nic -or $Nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) {
        return $false
    }

    try {
        $props = $Nic.GetIPProperties()
        $source = $props.UnicastAddresses |
            Where-Object {
                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                -not $_.Address.ToString().StartsWith("169.254.")
            } |
            Select-Object -First 1

        if (-not $source) { return $false }

        $client = New-Object System.Net.Sockets.TcpClient
        $client.ReceiveTimeout = 1500
        $client.SendTimeout = 1500
        $client.Client.Bind((New-Object System.Net.IPEndPoint -ArgumentList $source.Address, 0))
        $iar = $client.BeginConnect("1.1.1.1", 443, $null, $null)
        $connected = $iar.AsyncWaitHandle.WaitOne(1500, $false)

        if ($connected -and $client.Connected) {
            try { $client.EndConnect($iar) } catch {}
            $client.Close()
            return $true
        }

        $client.Close()
        return $false
    } catch {
        try { if ($client) { $client.Close() } } catch {}
        return $false
    }
}

function Fast-Update-Metrics {
    if (-not $global:CurrentIfaceName) { return }

    $allIfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()

    # CurrentIfaceName es el nombre visible de "Conexiones de red"
    # (NetConnectionID), mientras que NetworkInterface.Name puede ser
    # distinto para adaptadores virtuales. Usamos InterfaceIndex para
    # vincular ambos correctamente.
    $nic = $null
    if ($global:CurrentIfaceIndex -ge 0) {
        $nic = $allIfaces | Where-Object {
            try { $_.GetIPProperties().GetIPv4Properties().Index -eq $global:CurrentIfaceIndex }
            catch { $false }
        } | Select-Object -First 1
    }

    if (-not $nic -and $global:CurrentIfaceName) {
        $adapter = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.NetConnectionID -eq $global:CurrentIfaceName } |
            Select-Object -First 1

        if ($adapter) {
            $global:CurrentIfaceIndex = [int]$adapter.InterfaceIndex
            $nic = $allIfaces | Where-Object {
                try { $_.GetIPProperties().GetIPv4Properties().Index -eq $global:CurrentIfaceIndex }
                catch { $false }
            } | Select-Object -First 1
        }
    }

    if ($nic) {
        $global:IsConnected = ($nic.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up)

        # Estado de Internet: independiente del PingTarget.
        # Se comprueba periódicamente usando la IP de la interfaz elegida.
        if (-not $global:IsConnected) {
            $global:HasInternet = $false
            $global:InternetCheckAt = [DateTime]::MinValue
        } elseif (([DateTime]::Now - $global:InternetCheckAt).TotalSeconds -ge 5) {
            $global:HasInternet = Test-InterfaceInternet -Nic $nic
            $global:InternetCheckAt = [DateTime]::Now
        }

        if ($global:IsConnected) {
            $speedBps = $nic.Speed
            
            if ($speedBps -le 0) {
                $wmiAdapter = Get-CimInstance -Query "SELECT Speed FROM Win32_NetworkAdapter WHERE NetConnectionID = '$($global:CurrentIfaceName)'" -ErrorAction SilentlyContinue
                if ($wmiAdapter -and $wmiAdapter.Speed) {
                    $speedBps = [int64]$wmiAdapter.Speed
                }
            }

            if ($speedBps -ge 1000000000) {
                $gbps = $speedBps / 1000000000
                $global:LinkSpeed = if ($gbps % 1 -eq 0) { "$([int]$gbps) Gbps" } else { "$([math]::Round($gbps, 1)) Gbps" }
            } elseif ($speedBps -ge 1000000) {
                $mbps = $speedBps / 1000000
                $global:LinkSpeed = "$([int]$mbps) Mbps"
            } else {
                $global:LinkSpeed = "N/A"
            }

            $stats = $nic.GetIPStatistics()
            $bytes = $stats.BytesReceived
            $now = [DateTime]::Now

            if ($global:PrevBytes -gt 0) {
                $timeDiff = ($now - $global:PrevTime).TotalSeconds
                if ($timeDiff -gt 0) {
                    $bytesDiff = $bytes - $global:PrevBytes
                    if ($bytesDiff -ge 0) {
                        $global:RxMbps = [math]::Round((($bytesDiff * 8) / 1MB) / $timeDiff, 1)
                    }
                }
            }
            $global:PrevBytes = $bytes
            $global:PrevTime = $now

        } else {
            $global:LinkSpeed = "N/A"
            $global:RxMbps = 0.0
            $global:IsIdentifying = $false
            $global:HasInternet = $false
            $global:PingTimeMs = -1
            $global:PingTTL = -1
            $global:IdentifyUntil = $null
            $global:PingTimeoutEpisode = $false
            return
        }

        if ($null -ne $global:PingJob) {
            if ($global:PingJob.State -eq 'Completed') {
                $res = Receive-Job -Job $global:PingJob -ErrorAction SilentlyContinue
                Remove-Job -Job $global:PingJob -ErrorAction SilentlyContinue
                $global:PingJob = $null

                if ($res -and $res.Status -eq 'Success') {
                    # Respuesta recibida: NO mostrar "Aguarde" ni cuenta regresiva.
                    $global:PingTimeMs = [int]$res.ResponseTime
                    $global:PingTTL = if ($res.TTL -ne $null) { [int]$res.TTL } else { -1 }
                    $global:IsIdentifying = $false
                    $global:IdentifyUntil = $null
                    $global:PingTimeoutEpisode = $false
                } else {
                    # Timeout: mostrar "Aguarde" y comenzar la cuenta de 10 s.
                    $global:PingTimeMs = -1
                    $global:PingTTL = -1
                    if (-not $global:PingTimeoutEpisode) {
                        $global:IdentifyUntil = [DateTime]::Now.AddSeconds(10)
                        $global:PingTimeoutEpisode = $true
                    }
                    $global:IsIdentifying = ($null -ne $global:IdentifyUntil -and $global:IdentifyUntil -gt [DateTime]::Now)
                }
            } elseif ($global:PingJob.State -eq 'Failed' -or $global:PingJob.State -eq 'Stopped') {
                Remove-Job -Job $global:PingJob -Force -ErrorAction SilentlyContinue
                $global:PingJob = $null
                $global:PingTimeMs = -1
                $global:PingTTL = -1
                if ($null -eq $global:IdentifyUntil) {
                    $global:IdentifyUntil = [DateTime]::Now.AddSeconds(10)
                }
                $global:IsIdentifying = $true
            }
        } else {
            $target = if ($global:PingTarget) { $global:PingTarget } else { "8.8.8.8" }

            # Ping continuo: cada job realiza UN ping y luego se lanza el siguiente.
            # El ping no se detiene al recibir respuesta.
            $global:PingJob = Start-Job -ArgumentList $target -ScriptBlock {
                param($targetIp)
                try {
                    $p = New-Object System.Net.NetworkInformation.Ping
                    $reply = $p.Send($targetIp, 1000, (New-Object byte[] 32))
                    $ttl = -1
                    if ($reply.Options -and $reply.Options.Ttl) {
                        $ttl = [int]$reply.Options.Ttl
                    }
                    [pscustomobject]@{
                        Status       = [string]$reply.Status
                        ResponseTime = [int]$reply.RoundtripTime
                        TTL          = $ttl
                    }
                } catch {
                    [pscustomobject]@{
                        Status       = 'Failed'
                        ResponseTime = -1
                        TTL          = -1
                    }
                }
            }
        }
    }
}

$timer = New-Object System.Timers.Timer(500)
Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
    Fast-Update-Metrics
} | Out-Null
$timer.Start()

$htmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>Monitor de Interfaz</title>
    <style>
        body {
            background-color: #0f111a;
            color: #ffffff;
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
            padding: 20px 0;
        }
        .card {
            background: #1a1d2e;
            padding: 30px 40px;
            border-radius: 16px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.5);
            text-align: center;
            width: 520px;
        }
        h2 { margin-top: 0; color: #8a99ad; font-size: 1.1rem; text-transform: uppercase; letter-spacing: 2px; }
        .select-container, .ping-controls {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
        }
        select, input {
            background: #282c40;
            color: #fff;
            border: 1px solid #3d4463;
            padding: 10px 15px;
            border-radius: 8px;
            font-size: 0.95rem;
            flex: 1;
            outline: none;
        }
        select:focus, input:focus { border-color: #00e676; }
        .btn {
            background: #282c40;
            color: #fff;
            border: 1px solid #3d4463;
            padding: 0 16px;
            border-radius: 8px;
            font-size: 1rem;
            cursor: pointer;
            transition: all 0.2s ease;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .btn:hover { background: #3d4463; border-color: #00e676; color: #00e676; }
        .btn:active { transform: scale(0.95); }
        .digital-display {
            font-family: 'Courier New', Courier, monospace;
            font-size: 3.5rem;
            font-weight: bold;
            letter-spacing: -1px;
            margin: 15px 0;
            transition: color 0.3s ease;
        }
        .medium-display {
            font-family: 'Courier New', Courier, monospace;
            font-size: 2.2rem;
            font-weight: bold;
            margin: 8px 0 2px 0;
            transition: color 0.3s ease;
        }
        .label { color: #5c6980; font-size: 0.85rem; text-transform: uppercase; letter-spacing: 1px; }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; margin-top: 15px; }
        .box { background: #222638; padding: 20px 15px; border-radius: 12px; }
        
        .ping-box {
            position: relative;
            background: #151824;
            border: 1px solid #282c40;
            border-radius: 12px;
            padding: 15px;
            margin-top: 20px;
            text-align: left;
            overflow: hidden;
        }
        .ping-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 10px;
        }
        .ping-value {
            font-family: 'Courier New', Courier, monospace;
            font-size: 1.2rem;
            font-weight: bold;
            color: #00e676;
        }
        canvas {
            width: 100%;
            height: 120px;
            background: #0b0c14;
            border-radius: 8px;
            display: block;
        }
        .ping-overlay {
            display: none;
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: rgba(15, 17, 26, 0.88);
            backdrop-filter: blur(2px);
            z-index: 10;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            border-radius: 12px;
        }
        .ping-overlay.active {
            display: flex;
        }
        .spinner {
            width: 24px;
            height: 24px;
            border: 3px solid #ffcc00;
            border-top: 3px solid transparent;
            border-radius: 50%;
            animation: spin 1s linear infinite;
            margin-bottom: 8px;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        .overlay-text {
            color: #ffcc00;
            font-size: 0.9rem;
            font-weight: 600;
            letter-spacing: 0.5px;
        }
    </style>
</head>
<body>

<div class="card">
    <h2>MONITOR DE INTERFAZ</h2>
    
    <div class="select-container">
        <select id="ifaceSelect" onchange="changeIface()"></select>
        <button class="btn" onclick="loadInterfaces()" title="Recargar interfaces">&#128260;</button>
    </div>

    <div class="box">
        <div class="label">ENLACE NEGOCIADO</div>
        <div id="linkSpeedDisplay" class="digital-display">--</div>
    </div>

    <div class="grid">
        <div class="box">
            <div class="label">TR&Aacute;FICO DE DESCARGA</div>
            <div id="speedDisplay" class="medium-display">0.0</div>
            <div style="color: #8a99ad; font-size: 0.8rem; font-weight: 600;">Mbps</div>
        </div>

        <div class="box">
            <div class="label">ESTADO</div>
            <div id="statusDisplay" style="color: #ff4d4d; margin-top: 15px; font-weight: bold; font-size: 1.2rem;">Desconectado</div>
        </div>
    </div>

    <div class="ping-box">
        <div id="pingOverlay" class="ping-overlay">
            <div class="spinner"></div>
            <div class="overlay-text">Aguarde, identificando red...</div>
        </div>

        <div class="ping-header">
            <span class="label">MONITOR DE LATENCIA PING</span>
            <span id="pingVal" class="ping-value">-- ms</span>
        </div>
        
        <div class="ping-controls">
            <select id="ipSelect" onchange="selectIp()"></select>
            <input type="text" id="newIpInput" placeholder="Ej: 8.8.4.4 o 192.168.1.1">
            <button class="btn" onclick="addNewIp()">+ Agregar</button>
        </div>

        <canvas id="pingCanvas" width="440" height="120"></canvas>
    </div>
</div>

<script>
    const pingData = new Array(40).fill(null);
    const canvas = document.getElementById('pingCanvas');
    const ctx = canvas.getContext('2d');

    function getColor(val) {
        let num = typeof val === 'string' ? (val.includes('Gbps') ? parseFloat(val) * 1000 : parseFloat(val) || 0) : val;
        if (num <= 0) return '#ffffff';      
        if (num <= 10) return '#ff4d4d';     
        if (num <= 100) return '#ffcc00';    
        return '#00e676';                     
    }

    function drawChart() {
        const w = canvas.width;
        const h = canvas.height;
        ctx.clearRect(0, 0, w, h);

        ctx.strokeStyle = '#1a1d2e';
        ctx.lineWidth = 1;
        for(let i = 1; i < 4; i++) {
            ctx.beginPath();
            ctx.moveTo(0, (h / 4) * i);
            ctx.lineTo(w, (h / 4) * i);
            ctx.stroke();
        }

        const validValues = pingData.filter(v => v !== null && v >= 0);
        const maxVal = Math.max(100, ...validValues);

        ctx.beginPath();
        ctx.strokeStyle = '#00e676';
        ctx.lineWidth = 2;

        const step = w / (pingData.length - 1);

        for (let i = 0; i < pingData.length; i++) {
            const val = pingData[i];
            const x = i * step;

            if (val === null || val < 0) {
                const y = h - 5;
                if (i === 0) ctx.moveTo(x, y);
                else ctx.lineTo(x, y);
            } else {
                const y = h - ((val / maxVal) * (h - 20)) - 10;
                if (i === 0) ctx.moveTo(x, y);
                else ctx.lineTo(x, y);
            }
        }
        ctx.stroke();

        for (let i = 0; i < pingData.length; i++) {
            const val = pingData[i];
            if (val !== null) {
                const x = i * step;
                const y = val < 0 ? h - 5 : h - ((val / maxVal) * (h - 20)) - 10;
                ctx.beginPath();
                ctx.fillStyle = val < 0 ? '#ff4d4d' : (val > 120 ? '#ffcc00' : '#00e676');
                ctx.arc(x, y, 3, 0, Math.PI * 2);
                ctx.fill();
            }
        }
    }

    async function loadIPs() {
        try {
            const res = await fetch('/api/ips');
            const ips = await res.json();
            const select = document.getElementById('ipSelect');
            select.innerHTML = '';
            ips.forEach(ip => {
                const opt = document.createElement('option');
                opt.value = ip;
                opt.innerText = ip;
                select.appendChild(opt);
            });
            if (ips.length > 0) {
                select.value = ips[0];
                selectIp();
            }
        } catch(e) {}
    }

    async function selectIp() {
        const ip = document.getElementById('ipSelect').value;
        if (ip) {
            await fetch('/api/set-ping-target?ip=' + encodeURIComponent(ip));
            pingData.fill(null);
        }
    }

    async function addNewIp() {
        const input = document.getElementById('newIpInput');
        const ip = input.value.trim();
        if (ip) {
            const res = await fetch('/api/add-ip?ip=' + encodeURIComponent(ip), { method: 'POST' });
            const ips = await res.json();
            const select = document.getElementById('ipSelect');
            select.innerHTML = '';
            ips.forEach(item => {
                const opt = document.createElement('option');
                opt.value = item;
                opt.innerText = item;
                select.appendChild(opt);
            });
            select.value = ip;
            input.value = '';
            selectIp();
        }
    }

    async function loadInterfaces() {
        try {
            const select = document.getElementById('ifaceSelect');
            const currentVal = select.value;
            const res = await fetch('/api/interfaces');
            const data = await res.json();
            
            select.innerHTML = '';
            data.forEach(iface => {
                const opt = document.createElement('option');
                opt.value = iface;
                opt.innerText = iface;
                select.appendChild(opt);
            });

            if (data.length > 0) {
                if (data.includes(currentVal)) {
                    select.value = currentVal;
                } else {
                    // El backend ordena las interfaces activas primero.
                    select.selectedIndex = 0;
                    changeIface();
                }
            }
        } catch (e) {}
    }

    async function changeIface() {
        const iface = document.getElementById('ifaceSelect').value;
        if (iface) {
            await fetch('/api/set-iface?name=' + encodeURIComponent(iface)).catch(() => {});
            updateData();
        }
    }

    async function updateData() {
        try {
            const res = await fetch('/api/data');
            const data = await res.json();
            
            const linkDisplay = document.getElementById('linkSpeedDisplay');
            linkDisplay.innerText = data.linkSpeed;
            linkDisplay.style.color = getColor(data.linkSpeed);

            const speedDisplay = document.getElementById('speedDisplay');
            speedDisplay.innerText = data.rxMbps.toFixed(1);
            speedDisplay.style.color = getColor(data.rxMbps);

            const statusDisplay = document.getElementById('statusDisplay');
            const pingOverlay = document.getElementById('pingOverlay');

            // ESTADO: depende únicamente del acceso a Internet de la interfaz seleccionada.
            if (data.hasInternet) {
                statusDisplay.innerText = "Conectado";
                statusDisplay.style.color = "#00e676";
            } else {
                statusDisplay.innerText = "Desconectado";
                statusDisplay.style.color = "#ff4d4d";
            }

            // "Aguarde..." SOLO cuando el PingTarget está en Timeout.
            if (data.isIdentifying) {
                pingOverlay.classList.add('active');
                const remaining = Math.max(0, Math.ceil(data.identifyRemaining));
                document.querySelector('.overlay-text').innerText =
                    'Aguarde, identificando red... ' + remaining + 's';
            } else {
                pingOverlay.classList.remove('active');
            }

            const pingValDisplay = document.getElementById('pingVal');
            if (data.pingMs !== null && data.pingMs >= 0) {
                const ttlText = (data.pingTTL !== null && data.pingTTL >= 0)
                    ? ' | TTL ' + data.pingTTL
                    : '';
                pingValDisplay.innerText = data.pingMs + ' ms' + ttlText;
                pingValDisplay.style.color = data.pingMs > 120 ? '#ffcc00' : '#00e676';
            } else {
                pingValDisplay.innerText = 'Timeout | TTL --';
                pingValDisplay.style.color = '#ff4d4d';
            }

            pingData.shift();
            pingData.push(data.pingMs);
            drawChart();

        } catch (e) {}
    }

    loadInterfaces();
    loadIPs();
    setInterval(updateData, 500);
</script>

</body>
</html>
"@

$pendingTask = $null

try {
    while ($listener.IsListening) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -in 'q','Q','x','X') {
                Write-Host "`n[*] Cerrando servidor web..." -ForegroundColor Yellow
                break
            }
        }

        if ($null -eq $pendingTask) {
            $pendingTask = $listener.GetContextAsync()
        }

        if ($pendingTask.Wait(50)) {
            $context = $pendingTask.Result
            $pendingTask = $null

            $req = $context.Request
            $res = $context.Response
            $url = $req.Url.AbsolutePath

            try {
                if ($url -eq "/") {
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($htmlContent)
                    $res.ContentType = "text/html; charset=utf-8"
                    $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($url -eq "/api/interfaces") {
                    # Usar NetConnectionID de Win32_NetworkAdapter porque es
                    # el nombre que Windows muestra en "Conexiones de red".
                    # Esto evita mostrar adaptadores virtuales internos como
                    # "Conexión de área local* 1/2" cuando no aparecen en ncpa.cpl.
                    $ifaces = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
                        Where-Object {
                            $_.NetConnectionID -and
                            $_.NetConnectionID.Trim() -ne ""
                        } |
                        Sort-Object @{Expression={ if ($_.NetConnectionStatus -eq 2) { 0 } else { 1 } }}, NetConnectionID |
                        Select-Object -ExpandProperty NetConnectionID -Unique

                    $json = $ifaces | ConvertTo-Json
                    if (-not $json) { $json = "[]" }
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType = "application/json; charset=utf-8"
                    $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($url -eq "/api/ips") {
                    $json = Get-Content -Path $ipFilePath -Raw -Encoding UTF8
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType = "application/json; charset=utf-8"
                    $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($url -eq "/api/add-ip") {
                    $newIp = $req.QueryString["ip"]
                    if ($newIp) {
                        $ips = Get-Content -Path $ipFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ($ips -notcontains $newIp) {
                            $ips += $newIp
                            $ips | ConvertTo-Json | Set-Content -Path $ipFilePath -Encoding UTF8
                        }
                    }
                    $json = Get-Content -Path $ipFilePath -Raw -Encoding UTF8
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType = "application/json; charset=utf-8"
                    $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($url -eq "/api/set-ping-target") {
                    $newTarget = $req.QueryString["ip"]

                    if ($null -ne $global:PingJob) {
                        Remove-Job -Job $global:PingJob -Force -ErrorAction SilentlyContinue
                        $global:PingJob = $null
                    }

                    $global:PingTarget = $newTarget
                    $global:PingTimeMs = -1
                    $global:PingTTL = -1
                    $global:IsIdentifying = $false
                    $global:IdentifyUntil = $null
                    $global:PingTimeoutEpisode = $false

                    $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"status":"ok"}')
                    $res.ContentType = "application/json"
                    $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($url -eq "/api/set-iface") {
                    $global:CurrentIfaceName = $req.QueryString["name"]

                    $adapter = Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
                        Where-Object { $_.NetConnectionID -eq $global:CurrentIfaceName } |
                        Select-Object -First 1

                    if ($adapter) {
                        $global:CurrentIfaceIndex = [int]$adapter.InterfaceIndex
                    } else {
                        $global:CurrentIfaceIndex = -1
                    }

                    $global:RxMbps = 0.0
                    $global:PrevBytes = 0
                    $global:InternetCheckAt = [DateTime]::MinValue
                    $global:IsIdentifying = $false
                    $global:IdentifyUntil = $null
                    $global:PingTimeoutEpisode = $false
                    
                    Fast-Update-Metrics

                    $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"status":"ok"}')
                    $res.ContentType = "application/json"
                    $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($url -eq "/api/data") {
                    $identifyRemaining = 0
                    if ($global:IsIdentifying -and $null -ne $global:IdentifyUntil) {
                        $identifyRemaining = [math]::Max(0, ($global:IdentifyUntil - [DateTime]::Now).TotalSeconds)
                    }

                    $data = @{
                        rxMbps = $global:RxMbps
                        linkSpeed = $global:LinkSpeed
                        isConnected = $global:IsConnected
                        hasInternet = $global:HasInternet
                        isIdentifying = $global:IsIdentifying
                        identifyRemaining = $identifyRemaining
                        pingMs = $global:PingTimeMs
                        pingTTL = $global:PingTTL
                    }
                    $json = $data | ConvertTo-Json
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType = "application/json; charset=utf-8"
                    $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                else {
                    $res.StatusCode = 404
                }
            } catch {
            } finally {
                try { $res.Close() } catch {}
            }
        }
    }
} finally {
    if ($null -ne $global:PingJob) {
        Remove-Job -Job $global:PingJob -Force -ErrorAction SilentlyContinue
    }
    $timer.Stop()
    $timer.Dispose()
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
    Write-Host "[+] Puerto ${port} liberado correctamente." -ForegroundColor Green
}