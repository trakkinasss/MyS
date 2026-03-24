-- Espera o jogo carregar completamente
repeat task.wait(1) until game:IsLoaded()

local Players = game:GetService("Players")
repeat task.wait(1) until Players.LocalPlayer
local player = Players.LocalPlayer

-- HUD Ping + Server Hopper | Numpad 5 = novo server | Numpad 8 = reentrar | Numpad 2 = voltar ao servidor anterior
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")

local placeId = game.PlaceId
local currentJobId = game.JobId
local hopping = false
local autoHop = false
local autoHopCooldown = false
local AUTOHOP_PING_THRESHOLD = 250 -- ms

-- Buffer para calcular o ping mais recorrente
local PING_BUFFER_SIZE = 20  -- quantas amostras guardar (~20 segundos)
local PING_BUCKET_SIZE = 10  -- agrupa pings em faixas de 10ms (ex: 120~129 = bucket 120)
local pingBuffer = {}

-- Recupera o servidor anterior salvo em disco pelo executor
local previousJobId = nil
local SAVE_FILE        = "mys_previous_server.txt"
local AUTOHOP_FILE     = "mys_autohop.txt"
local GOOD_SERVERS_FILE = "mys_good_servers.txt"

-- Configurações dos servidores bons
local MAX_GOOD_SERVERS      = 25
local GOOD_PING_THRESHOLD   = 150  -- ms
local GOOD_PING_TIME_NEEDED = 60   -- segundos consecutivos abaixo do threshold para salvar

local goodServers = {}   -- lista de jobIds bons
local goodPingTimer = 0  -- contador de segundos com ping bom no server atual

pcall(function()
    if isfile and isfile(SAVE_FILE) then
        local saved = readfile(SAVE_FILE)
        if saved and #saved > 10 then
            previousJobId = saved
        end
    end
end)

-- Carrega lista de servidores bons
pcall(function()
    if isfile and isfile(GOOD_SERVERS_FILE) then
        local raw = readfile(GOOD_SERVERS_FILE)
        local decoded = HttpService:JSONDecode(raw)
        if type(decoded) == "table" then
            goodServers = decoded
        end
    end
end)

-- Carrega estado do auto-hop salvo
pcall(function()
    if isfile and isfile(AUTOHOP_FILE) then
        autoHop = readfile(AUTOHOP_FILE) == "true"
    end
end)
local currentColorKey = "good"
local t = 0

-- ============================================================
-- CONFIGURAÇÃO: ping máximo aceito ao hopar (em milissegundos)
-- Servidores com ping acima desse valor serão ignorados.
-- Coloque math.huge para desativar o filtro.
-- ============================================================
local MAX_HOP_PING = 100 -- ms

-- Paletas RGB — tema Cosmos (violeta › azul › ciano › verde › rosa › vermelho › laranja)
local PALETTES = {
    good      = { Color3.fromHex("#A78BFA"), Color3.fromHex("#7C3AED") }, -- violeta suave
    medium    = { Color3.fromHex("#93C5FD"), Color3.fromHex("#3B82F6") }, -- azul claro
    high      = { Color3.fromHex("#F9A8D4"), Color3.fromHex("#EC4899") }, -- rosa médio
    bad       = { Color3.fromHex("#FCA5A5"), Color3.fromHex("#EF4444") }, -- vermelho suave
    hopping   = { Color3.fromHex("#A5B4FC"), Color3.fromHex("#6366F1") }, -- índigo
    rejoining = { Color3.fromHex("#7DD3FC"), Color3.fromHex("#0EA5E9") }, -- azul céu
    noping    = { Color3.fromHex("#FDBA74"), Color3.fromHex("#F97316") }, -- laranja
    returning = { Color3.fromHex("#F0ABFC"), Color3.fromHex("#D946EF") }, -- fúcsia
    autohop   = { Color3.fromHex("#6EE7B7"), Color3.fromHex("#10B981") }, -- verde esmeralda
    goodserver = { Color3.fromHex("#5EEAD4"), Color3.fromHex("#14B8A6") }, -- ciano-teal
}

local function lerpColor(a, b, alpha)
    return Color3.new(
        a.R + (b.R - a.R) * alpha,
        a.G + (b.G - a.G) * alpha,
        a.B + (b.B - a.B) * alpha
    )
end

local function getAnimatedColor(key)
    local palette = PALETTES[key]
    local alpha = (math.sin(t * 2) + 1) / 2
    return lerpColor(palette[1], palette[2], alpha)
end

-- ScreenGui
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PingHopDisplay"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = player.PlayerGui

-- Frame principal
local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 90, 0, 34)
frame.Position = UDim2.new(1, -105, 0, -30)
frame.BackgroundColor3 = Color3.fromRGB(18, 14, 32) -- fundo roxo-escuro harmonioso com o tema Cosmos
frame.BackgroundTransparency = 0.35
frame.BorderSizePixel = 0
frame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = PALETTES.good[1]
stroke.Thickness = 1.8
stroke.Parent = frame

local glow = Instance.new("ImageLabel")
glow.Size = UDim2.new(1, 0, 1, 0)
glow.Position = UDim2.new(0, 0, 0, 0)
glow.BackgroundTransparency = 1
glow.Image = "rbxassetid://5028857084"
glow.ImageTransparency = 0.88
glow.ImageColor3 = PALETTES.good[1]
glow.ScaleType = Enum.ScaleType.Stretch
glow.ZIndex = 1
glow.Parent = frame

local glowCorner = Instance.new("UICorner")
glowCorner.CornerRadius = UDim.new(0, 10)
glowCorner.Parent = glow

local pingLabel = Instance.new("TextLabel")
pingLabel.Size = UDim2.new(1, 0, 1, 0)
pingLabel.Position = UDim2.new(0, 0, 0, 0)
pingLabel.BackgroundTransparency = 1
pingLabel.Text = "-- ms"
pingLabel.TextColor3 = PALETTES.good[1]
pingLabel.TextSize = 15
pingLabel.Font = Enum.Font.GothamBold
pingLabel.TextXAlignment = Enum.TextXAlignment.Center
pingLabel.ZIndex = 2
pingLabel.Parent = frame

-- Label de toggle do auto-hop (aparece no hover)
local toggleLabel = Instance.new("TextLabel")
toggleLabel.Size = UDim2.new(1, 0, 1, 0)
toggleLabel.Position = UDim2.new(0, 0, 0, 0)
toggleLabel.BackgroundTransparency = 1
toggleLabel.Text = "Desativado"
toggleLabel.Text = autoHop and "Ativado" or "Desativado"
toggleLabel.TextColor3 = PALETTES.autohop[1]
toggleLabel.TextTransparency = 1 -- começa invisível
toggleLabel.TextSize = 13
toggleLabel.Font = Enum.Font.GothamBold
toggleLabel.TextXAlignment = Enum.TextXAlignment.Center
toggleLabel.ZIndex = 3
toggleLabel.Parent = frame

local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local isHovered = false

local function setHover(hovered)
    isHovered = hovered
    TweenService:Create(pingLabel,  tweenInfo, { TextTransparency = hovered and 1 or 0 }):Play()
    TweenService:Create(toggleLabel, tweenInfo, { TextTransparency = hovered and 0 or 1 }):Play()
end

-- Clique no frame: toggle do auto-hop
frame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        autoHop = not autoHop
        toggleLabel.Text = autoHop and "Ativado" or "Desativado"
        pcall(function() writefile(AUTOHOP_FILE, tostring(autoHop)) end)
    end
end)

frame.MouseEnter:Connect(function() setHover(true) end)
frame.MouseLeave:Connect(function() setHover(false) end)

-- Cor do ping
local function getPingColorKey(ping)
    if ping <= 83 then return "good"
    elseif ping <= 166 then return "medium"
    elseif ping <= 250 then return "high"
    else return "bad"
    end
end

-- Heartbeat
RunService.Heartbeat:Connect(function(dt)
    t = t + dt

    if not hopping then
        local ping = math.floor(player:GetNetworkPing() * 1000)
        pingLabel.Text = ping .. " ms"
        currentColorKey = getPingColorKey(ping)

        -- Auto-hop: troca de server se ping > threshold
        -- (disparado após hopServer ser definida — ver abaixo)
    end

    local color = getAnimatedColor(currentColorKey)
    pingLabel.TextColor3 = color
    toggleLabel.TextColor3 = color
    stroke.Color = color
    glow.ImageColor3 = color
end)

-- Server Hopper
local function getServers(cursor)
    local url = "https://games.roblox.com/v1/games/" .. placeId .. "/servers/Public?sortOrder=Asc&limit=100"
    if cursor then url = url .. "&cursor=" .. cursor end

    local ok, result = pcall(function()
        return HttpService:JSONDecode(game:HttpGet(url))
    end)

    if ok and result and result.data then
        return result.data, result.nextPageCursor
    end
    return nil, nil
end

local function findDifferentServer()
    local servers, cursor = getServers(nil)
    if not servers then return nil end

    local allServers = {}
    for _, s in ipairs(servers) do table.insert(allServers, s) end

    if cursor then
        local more = getServers(cursor)
        if more then
            for _, s in ipairs(more) do table.insert(allServers, s) end
        end
    end

    local valid = {}
    for _, server in ipairs(allServers) do
        -- Verifica se o servidor é diferente, tem vagas e está dentro do limite de ping
        local serverPing = server.ping or math.huge
        if server.id ~= currentJobId
            and server.playing ~= nil
            and server.maxPlayers ~= nil
            and server.playing < server.maxPlayers
            and serverPing <= MAX_HOP_PING
        then
            table.insert(valid, server)
        end
    end

    -- Se nenhum servidor passar no filtro de ping, avisa no HUD e cancela
    if #valid == 0 then return nil, true end

    return valid[math.random(1, #valid)].id, false
end

-- Numpad 5: trocar de servidor
local function hopServer(keepColor)
    if hopping then return end
    hopping = true
    if not keepColor then currentColorKey = "hopping" end

    local jobId, noPingServer = findDifferentServer()

    if jobId then
        -- Salva o servidor atual em disco antes de teleportar
        pcall(function() writefile(SAVE_FILE, currentJobId) end)
        task.wait(1)
        local ok, err = pcall(function()
            TeleportService:TeleportToPlaceInstance(placeId, jobId, player)
        end)
        if not ok then
            currentColorKey = "noping"
            pingLabel.Text = "erro hop"
            task.wait(2)
            pingLabel.Text = "-- ms"
            hopping = false
        end
    else
        -- Nenhum servidor encontrou o filtro de ping: mostra cor de aviso por 2s
        if noPingServer then
            currentColorKey = "noping"
            pingLabel.Text = "sem server"
            task.wait(2)
            pingLabel.Text = "-- ms"
        end
        hopping = false
    end
end

-- Salva a lista de servidores bons no disco
local function saveGoodServers()
    pcall(function()
        writefile(GOOD_SERVERS_FILE, HttpService:JSONEncode(goodServers))
    end)
end

-- Registra o servidor atual como bom (se ainda não estiver na lista)
local function registerGoodServer()
    for _, id in ipairs(goodServers) do
        if id == currentJobId then return end -- já está salvo
    end
    table.insert(goodServers, currentJobId)
    if #goodServers > MAX_GOOD_SERVERS then
        table.remove(goodServers, 1) -- remove o mais antigo
    end
    saveGoodServers()
end

-- Calcula o ping mais recorrente no buffer (moda por bucket)
local function getModePing()
    if #pingBuffer == 0 then return 0 end
    local counts = {}
    for _, p in ipairs(pingBuffer) do
        local bucket = math.floor(p / PING_BUCKET_SIZE) * PING_BUCKET_SIZE
        counts[bucket] = (counts[bucket] or 0) + 1
    end
    local modeVal, modeCount = 0, 0
    for bucket, count in pairs(counts) do
        if count > modeCount then
            modeCount = count
            modeVal = bucket
        end
    end
    return modeVal
end

-- Loop de auto-hop (roda após hopServer estar definida)
task.spawn(function()
    while true do
        task.wait(1)

        -- Atualiza o buffer de pings a cada segundo
        local ping = math.floor(player:GetNetworkPing() * 1000)
        table.insert(pingBuffer, ping)
        if #pingBuffer > PING_BUFFER_SIZE then
            table.remove(pingBuffer, 1)
        end

        -- Rastreia tempo consecutivo com ping bom para salvar o servidor
        if not hopping then
            if ping < GOOD_PING_THRESHOLD then
                goodPingTimer = goodPingTimer + 1
                if goodPingTimer >= GOOD_PING_TIME_NEEDED then
                    registerGoodServer()
                end
            else
                goodPingTimer = 0 -- reseta se o ping piorou
            end
        end

        if autoHop and not hopping and not autoHopCooldown then
            local modePing = getModePing()
            if modePing > AUTOHOP_PING_THRESHOLD then
                autoHopCooldown = true
                currentColorKey = "autohop"
                hopServer(true)
                task.wait(10)
                pingBuffer = {} -- limpa o buffer após hopar para não re-disparar com amostras antigas
                autoHopCooldown = false
            end
        end
    end
end)

-- Numpad 8: reentrar no mesmo servidor
local function rejoinServer()
    if hopping then return end
    hopping = true
    currentColorKey = "rejoining"
    task.wait(1)
    local ok = pcall(function()
        TeleportService:TeleportToPlaceInstance(placeId, currentJobId, player)
    end)
    if not ok then
        currentColorKey = "noping"
        pingLabel.Text = "erro hop"
        task.wait(2)
        pingLabel.Text = "-- ms"
        hopping = false
    end
end

-- Numpad 2: voltar ao servidor anterior
local function returnToPreviousServer()
    if hopping then return end
    if not previousJobId then
        -- Sem servidor anterior registrado: pisca rosa por 2s
        currentColorKey = "returning"
        pingLabel.Text = "sem anterior"
        task.wait(2)
        pingLabel.Text = "-- ms"
        currentColorKey = getPingColorKey(math.floor(player:GetNetworkPing() * 1000))
        return
    end
    hopping = true
    currentColorKey = "returning"
    pcall(function() writefile(SAVE_FILE, currentJobId) end)
    task.wait(1)
    local ok = pcall(function()
        TeleportService:TeleportToPlaceInstance(placeId, previousJobId, player)
    end)
    if not ok then
        currentColorKey = "noping"
        pingLabel.Text = "erro hop"
        task.wait(2)
        pingLabel.Text = "-- ms"
        hopping = false
    end
end

-- Numpad 6: ir para um servidor bom salvo
local function hopToGoodServer()
    if hopping then return end

    -- Filtra fora o servidor atual
    local candidates = {}
    for _, id in ipairs(goodServers) do
        if id ~= currentJobId then
            table.insert(candidates, id)
        end
    end

    -- Sem candidatos: fallback para hop normal
    if #candidates == 0 then
        hopServer()
        return
    end

    hopping = true
    currentColorKey = "goodserver"
    pcall(function() writefile(SAVE_FILE, currentJobId) end)

    -- Tenta cada candidato até achar um que funcione
    local teleported = false
    while #candidates > 0 do
        local idx = math.random(1, #candidates)
        local target = candidates[idx]
        table.remove(candidates, idx)

        task.wait(1)
        local ok = pcall(function()
            TeleportService:TeleportToPlaceInstance(placeId, target, player)
        end)

        if ok then
            -- Remove o servidor da lista de bons pois já foi usado
            for i, id in ipairs(goodServers) do
                if id == target then
                    table.remove(goodServers, i)
                    saveGoodServers()
                    break
                end
            end
            teleported = true
            break
        else
            -- Remove servidor inválido da lista salva
            for i, id in ipairs(goodServers) do
                if id == target then
                    table.remove(goodServers, i)
                    saveGoodServers()
                    break
                end
            end
        end
    end

    if not teleported then
        currentColorKey = "noping"
        pingLabel.Text = "sem server"
        task.wait(2)
        pingLabel.Text = "-- ms"
        hopping = false
    end
end

-- Watchdog: reseta o script se o hopping ficar travado por mais de 15s
task.spawn(function()
    local lastHopStart = 0
    while true do
        task.wait(1)
        if hopping then
            lastHopStart = lastHopStart + 1
            if lastHopStart >= 15 then
                hopping = false
                autoHopCooldown = false
                currentColorKey = "good"
                pingLabel.Text = "-- ms"
                lastHopStart = 0
            end
        else
            lastHopStart = 0
        end
    end
end)

-- Inputs
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.KeypadFive then
        hopServer()
    elseif input.KeyCode == Enum.KeyCode.KeypadEight then
        rejoinServer()
    elseif input.KeyCode == Enum.KeyCode.KeypadTwo then
        returnToPreviousServer()
    elseif input.KeyCode == Enum.KeyCode.KeypadSix then
        hopToGoodServer()
    end
end)