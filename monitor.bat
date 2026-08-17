<# :
@echo off
chcp 65001 >nul
title Servidor Web Monitor de Red

:: Verificar permisos de Administrador
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [!] Ejecuta este script como Administrador para habilitar el servidor web.
    pause
    exit /b
)

echo ===================================================
echo     INICIANDO MONITOR DE RED WEB
echo ===================================================
echo.

set /p USER_PORT="Ingrese el puerto a utilizar [Presiona ENTER para 8080]: "
if "%USER_PORT%"=="" set USER_PORT=8080
set TARGET_PORT=%USER_PORT%

echo.
echo [*] Limpiando procesos previos en el puerto %TARGET_PORT%...
for /f "tokens=5" %%a in ('netstat -aon ^| findstr /r /c:":%TARGET_PORT% *LISTENING"') do (
    taskkill /F /PID %%a >nul 2>&1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([System.IO.File]::ReadAllText('%~f0'))"
pause
exit /b
#>

# --- CÓDIGO POWERSHELL: SERVIDOR HTTP Y MONITOR ---
Import-Module NetTCPIP -ErrorAction SilentlyContinue

$port = [int]$env:TARGET_PORT
if ($port -le 0) { $port = 8080 }

# Verificar si el puerto sigue ocupado
$portActive = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if ($portActive) {
    Write-Host "[!] El puerto $port no se pudo liberar (PID $($portActive.OwningProcess))." -ForegroundColor Red
    return
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:${port}/")

try {
    $listener.Start()
} catch {
    $listener.Prefixes.Clear()
    $listener.Prefixes.Add("http://localhost:${port}/")
    $listener.Prefixes.Add("http://127.0.0.1:${port}/")
    try {
        $listener.Start()
    } catch {
        Write-Host "[!] Error al iniciar HttpListener en puerto ${port} - $_" -ForegroundColor Red
        return
    }
}

# Verificación directa de conectividad TCP local
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

# Limpiar buffer de teclado residual
while ([Console]::KeyAvailable) {
    [Console]::ReadKey($true) | Out-Null
}

$global:CurrentIface = ""
$global:RxMbps = 0
$global:LinkSpeed = "N/A"
$global:IsConnected = $false
$global:PrevBytes = 0
$global:PrevTime = [DateTime]::Now

# Timer de muestreo en segundo plano
$timer = New-Object System.Timers.Timer(1000)
Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
    if ($global:CurrentIface) {
        # Verificación de salida a Internet en la interfaz seleccionada
        $profile = Get-NetConnectionProfile -InterfaceAlias $global:CurrentIface -ErrorAction SilentlyContinue
        if ($profile -and ($profile.IPv4Connectivity -eq 'Internet' -or $profile.IPv6Connectivity -eq 'Internet')) {
            $global:IsConnected = $true
        } else {
            $global:IsConnected = $false
        }

        $adapter = Get-NetAdapter -Name $global:CurrentIface -ErrorAction SilentlyContinue
        if ($adapter) {
            $global:LinkSpeed = $adapter.LinkSpeed
            $stat = Get-NetAdapterStatistics -Name $global:CurrentIface -ErrorAction SilentlyContinue
            if ($stat) {
                $now = [DateTime]::Now
                $bytes = $stat.ReceivedBytes
                if ($global:PrevBytes -gt 0) {
                    $timeDiff = ($now - $global:PrevTime).TotalSeconds
                    if ($timeDiff -gt 0) {
                        $bytesDiff = $bytes - $global:PrevBytes
                        $global:RxMbps = [math]::Round((($bytesDiff * 8) / 1Mb) / $timeDiff, 1)
                    }
                }
                $global:PrevBytes = $bytes
                $global:PrevTime = $now
            }
        }
    }
} | Out-Null
$timer.Start()

$htmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>Monitor de Red - Tiempo Real</title>
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
        }
        .card {
            background: #1a1d2e;
            padding: 30px 50px;
            border-radius: 16px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.5);
            text-align: center;
            width: 460px;
        }
        h2 { margin-top: 0; color: #8a99ad; font-size: 1.1rem; text-transform: uppercase; letter-spacing: 2px; }
        .select-container {
            display: flex;
            gap: 10px;
            margin-bottom: 25px;
        }
        select {
            background: #282c40;
            color: #fff;
            border: 1px solid #3d4463;
            padding: 10px 15px;
            border-radius: 8px;
            font-size: 1rem;
            flex: 1;
            outline: none;
            cursor: pointer;
        }
        .btn-refresh {
            background: #282c40;
            color: #fff;
            border: 1px solid #3d4463;
            padding: 0 16px;
            border-radius: 8px;
            font-size: 1.1rem;
            cursor: pointer;
            transition: all 0.2s ease;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .btn-refresh:hover {
            background: #3d4463;
            border-color: #00e676;
            color: #00e676;
        }
        .btn-refresh:active {
            transform: scale(0.95);
        }
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
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; margin-top: 20px; }
        .box { background: #222638; padding: 20px 15px; border-radius: 12px; }
    </style>
</head>
<body>

<div class="card">
    <h2>Monitor de Interfaz</h2>
    
    <div class="select-container">
        <select id="ifaceSelect" onchange="changeIface()"></select>
        <button class="btn-refresh" onclick="loadInterfaces()" title="Recargar interfaces de red">🔄</button>
    </div>

    <div class="box">
        <div class="label">Enlace Negociado</div>
        <div id="linkSpeedDisplay" class="digital-display">--</div>
    </div>

    <div class="grid">
        <div class="box">
            <div class="label">Tráfico de Descarga</div>
            <div id="speedDisplay" class="medium-display">0.0</div>
            <div style="color: #8a99ad; font-size: 0.8rem; font-weight: 600;">Mbps</div>
        </div>

        <div class="box">
            <div class="label">Estado</div>
            <div id="statusDisplay" style="color: #ff4d4d; margin-top: 15px; font-weight: bold; font-size: 1.2rem;">Desconectado</div>
        </div>
    </div>
</div>

<script>
    function getColor(val) {
        let num = 0;
        if (typeof val === 'string') {
            if (val.includes('Gbps')) {
                num = parseFloat(val) * 1000;
            } else {
                num = parseFloat(val) || 0;
            }
        } else {
            num = val;
        }

        if (num <= 0) return '#ffffff';      
        if (num <= 10) return '#ff4d4d';     
        if (num <= 100) return '#ffcc00';    
        return '#00e676';                     
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
                // Mantener selección previa si la interfaz sigue estando conectada
                if (data.includes(currentVal)) {
                    select.value = currentVal;
                } else {
                    changeIface();
                }
            }
        } catch (e) {}
    }

    async function changeIface() {
        const iface = document.getElementById('ifaceSelect').value;
        if (iface) {
            await fetch('/api/set-iface?name=' + encodeURIComponent(iface)).catch(() => {});
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
            if (data.isConnected) {
                statusDisplay.innerText = "Conectado";
                statusDisplay.style.color = "#00e676";
            } else {
                statusDisplay.innerText = "Desconectado";
                statusDisplay.style.color = "#ff4d4d";
            }
        } catch (e) {}
    }

    loadInterfaces();
    setInterval(updateData, 1000);
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

        if ($pendingTask.Wait(200)) {
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
                    $ifaces = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty Name
                    $json = $ifaces | ConvertTo-Json
                    if (-not $json) { $json = "[]" }
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType = "application/json"
                    $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($url -eq "/api/set-iface") {
                    $global:CurrentIface = $req.QueryString["name"]
                    $global:PrevBytes = 0
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"status":"ok"}')
                    $res.ContentType = "application/json"
                    $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif ($url -eq "/api/data") {
                    $data = @{
                        rxMbps = $global:RxMbps
                        linkSpeed = $global:LinkSpeed
                        isConnected = $global:IsConnected
                    }
                    $json = $data | ConvertTo-Json
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                else {
                    $res.StatusCode = 404
                }
            } catch {
                # Ignorar desconexiones del cliente
            } finally {
                try { $res.Close() } catch {}
            }
        }
    }
} finally {
    $timer.Stop()
    $timer.Dispose()
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
    Write-Host "[+] Puerto ${port} liberado correctamente." -ForegroundColor Green
}