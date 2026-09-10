assert(Drawing and type(Drawing.new) == "function",
    "GameSense.exe requires Drawing API.")
assert(imgui and type(imgui.create) == "function",
    "GameSense.exe requires imgui.create API.")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local environment = getgenv()
local previous = environment.GameSenseOverlay
if previous and type(previous.Unload) == "function" then previous.Unload() end
local legacy = environment.KnifeDuelOverlay
if legacy and legacy ~= previous and type(legacy.Unload) == "function" then legacy.Unload() end

local lockBinding = "GameSensePlayerLock_" .. HttpService:GenerateGUID(false)
local overlayBinding = lockBinding .. "_Overlay"
local lockEnabled = false
local espEnabled = false
local showFOV = false
local fovRadius = 150
local aimSmoothness = 35
local throwPrediction = true
local knifeSpeed = 150
local autoRMBEnabled = false
local lastRMBClick = -math.huge
local rmbClickInterval = 0.2
local clickRMB = type(mouse2click) == "function" and mouse2click or nil
local lockKey = Enum.KeyCode.V
local visibilityParams = RaycastParams.new()
visibilityParams.FilterType = Enum.RaycastFilterType.Exclude
local running = true
local window = nil
local menuVisible = true
local menuGeneration = 0
local menuRefreshPending = false
local rebuildMenu
local noticeText = "K: menu | V: lock | End: unload"
local drawings = {}
local playerBoxes = {}
local connections = {}
local trackedPlayers = {}
local boundsCache = {}
local drawState = {}
local overlayElapsed = 0
local overlayInterval = 1 / 30
local boundsInterval = 0.2
local gameFocused = true
if type(isrbxactive) == "function" then
    local ok, focused = pcall(isrbxactive)
    if ok and type(focused) == "boolean" then gameFocused = focused end
end
local diagnostics = { overlayTicks = 0, lockTicks = 0, callbacks = 0, error = "none" }
local drawingHealthy = true

local function trackPlayer(player)
    if player ~= Players.LocalPlayer then trackedPlayers[player] = true end
end

local function setDrawing(object, key, value)
    local state = drawState[object]
    if state[key] ~= value then
        object[key] = value
        state[key] = value
    end
end

local function requestMenuRefresh()
    if menuRefreshPending or not running then return end
    menuRefreshPending = true
    task.defer(function()
        menuRefreshPending = false
        if running and menuVisible and rebuildMenu then rebuildMenu() end
    end)
end

local function notice(message)
    noticeText = tostring(message)
    print("[GameSense.exe] " .. noticeText)
    requestMenuRefresh()
end

local function removeDrawing(object)
    if not object then return end
    pcall(function() object.Visible = false end)
    local ok = pcall(function() object:Destroy() end)
    if not ok then pcall(function() object:Remove() end) end
    drawings[object] = nil
    drawState[object] = nil
end

local function newDrawing(kind, properties)
    local object = Drawing.new(kind)
    drawings[object] = true
    drawState[object] = { Visible = false }
    local ok, err = pcall(function()
        object.Visible = false
        setDrawing(object, "Transparency", 0.5)
        for key, value in pairs(properties) do setDrawing(object, key, value) end
    end)
    if not ok then removeDrawing(object); error(err, 0) end
    return object
end

local fovCircle = newDrawing("Circle", {
    Radius = fovRadius, NumSides = 96, Thickness = 1.5,
    Filled = false, Color = Color3.fromRGB(255, 255, 255),
})

local function removePlayer(player)
    removeDrawing(playerBoxes[player])
    playerBoxes[player] = nil
    trackedPlayers[player] = nil
    boundsCache[player] = nil
end

local function setESP(enabled)
    espEnabled = enabled
    if not enabled then
        for player, box in pairs(playerBoxes) do
            removeDrawing(box)
            playerBoxes[player] = nil
        end
        table.clear(boundsCache)
    end
end

local function projectBox(camera, character, player, now)
    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local cached = boundsCache[player]
    if not cached or cached.character ~= character or cached.root ~= root or now >= cached.expires then
        local transform, size = character:GetBoundingBox()
        local corners = {}
        local relative = root.CFrame:ToObjectSpace(transform)
        for x = -1, 1, 2 do
            for y = -1, 1, 2 do
                for z = -1, 1, 2 do
                    corners[#corners + 1] = relative:PointToWorldSpace(Vector3.new(
                        x * size.X / 2, y * size.Y / 2, z * size.Z / 2))
                end
            end
        end
        cached = { character = character, root = root, corners = corners, expires = now + boundsInterval }
        boundsCache[player] = cached
    end
    local transform = root.CFrame
    local minimumX, minimumY = math.huge, math.huge
    local maximumX, maximumY = -math.huge, -math.huge
    for _, offset in ipairs(cached.corners) do
        local corner = transform:PointToWorldSpace(offset)
        local projected = camera:WorldToViewportPoint(corner)
        if projected.Z <= 0.1 then return nil end
        minimumX = math.min(minimumX, projected.X)
        minimumY = math.min(minimumY, projected.Y)
        maximumX = math.max(maximumX, projected.X)
        maximumY = math.max(maximumY, projected.Y)
    end
    local viewport = camera.ViewportSize
    if maximumX < 0 or maximumY < 0 or minimumX > viewport.X or minimumY > viewport.Y then
        return nil
    end
    minimumX, minimumY = math.max(0, minimumX), math.max(0, minimumY)
    maximumX, maximumY = math.min(viewport.X, maximumX), math.min(viewport.Y, maximumY)
    if maximumX <= minimumX or maximumY <= minimumY then return nil end
    return Vector2.new(minimumX, minimumY), Vector2.new(maximumX - minimumX, maximumY - minimumY)
end

local function updateOverlay()
    if not showFOV and not espEnabled then
        setDrawing(fovCircle, "Visible", false)
        return
    end
    local camera = workspace.CurrentCamera
    local active = camera ~= nil and gameFocused
    setDrawing(fovCircle, "Visible", active and showFOV)
    if active and showFOV then
        setDrawing(fovCircle, "Position", camera.ViewportSize / 2)
        setDrawing(fovCircle, "Radius", fovRadius)
    end
    if not active or not espEnabled then
        for _, box in pairs(playerBoxes) do setDrawing(box, "Visible", false) end
        return
    end
    local now = os.clock()
    for player in pairs(trackedPlayers) do
        local box = playerBoxes[player]
        local visible = false
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid and humanoid.Health > 0 and character:IsDescendantOf(workspace) then
            local position, size = projectBox(camera, character, player, now)
            if position then
                if not box then
                    box = newDrawing("Square", {
                        Filled = false, Thickness = 1.5, Color = Color3.fromRGB(255, 80, 80),
                    })
                    playerBoxes[player] = box
                end
                setDrawing(box, "Position", position)
                setDrawing(box, "Size", size)
                visible = true
            end
        end
        if box then setDrawing(box, "Visible", visible) end
    end
end

local function findFOVTarget(camera)
    local center = camera.ViewportSize / 2
    local closestDistance = fovRadius * fovRadius
    local closestTarget = nil

    for player in pairs(trackedPlayers) do
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local target = character and character:FindFirstChild("Head")

        if humanoid and humanoid.Health > 0 and target and target:IsA("BasePart")
            and target:IsDescendantOf(workspace) then
            local projected, onScreen = camera:WorldToViewportPoint(target.Position)
            if onScreen and projected.Z > 0 then
                local dx, dy = projected.X - center.X, projected.Y - center.Y
                local distance = dx * dx + dy * dy
                if distance <= closestDistance then
                    closestDistance = distance
                    closestTarget = target
                end
            end
        end
    end

    return closestTarget
end

local function isHeadVisible(camera, head)
    if head.Transparency >= 1 or head.LocalTransparencyModifier >= 1 then
        return false
    end
    local projected, onScreen = camera:WorldToViewportPoint(head.Position)
    if not onScreen or projected.Z <= 0 then
        return false
    end

    local localCharacter = Players.LocalPlayer.Character
    visibilityParams.FilterDescendantsInstances = localCharacter and { localCharacter } or {}
    local origin = camera.CFrame.Position
    local hit = workspace:Raycast(origin, head.Position - origin, visibilityParams)
    return hit == nil or hit.Instance:IsDescendantOf(head.Parent)
end

local function predictThrow(origin, head)
    local offset = head.Position - origin
    local velocity = head.AssemblyLinearVelocity
    local a = velocity:Dot(velocity) - knifeSpeed * knifeSpeed
    local b = 2 * offset:Dot(velocity)
    local c = offset:Dot(offset)
    local time = nil
    if math.abs(a) < 0.001 then
        if math.abs(b) > 0.001 then
            time = -c / b
        end
    else
        local discriminant = b * b - 4 * a * c
        if discriminant >= 0 then
            local root = math.sqrt(discriminant)
            local first = (-b - root) / (2 * a)
            local second = (-b + root) / (2 * a)
            if first > 0 then time = first end
            if second > 0 and (not time or second < time) then time = second end
        end
    end
    if not time or time <= 0 or time > 3 then
        return nil
    end
    return head.Position + velocity * time
end

local function getThrowOrigin(camera)
    local character = Players.LocalPlayer.Character
    local tool = character and character:FindFirstChildOfClass("Tool")
    local handle = tool and tool:FindFirstChild("Handle")
    local hand = character and (character:FindFirstChild("RightHand")
        or character:FindFirstChild("Right Arm"))
    local part = handle or hand
    return part and part:IsA("BasePart") and part.Position or camera.CFrame.Position
end

local function hasClearThrowPath(origin, destination, head)
    local character = Players.LocalPlayer.Character
    visibilityParams.FilterDescendantsInstances = character and { character } or {}
    local hit = workspace:Raycast(origin, destination - origin, visibilityParams)
    return hit == nil or hit.Instance:IsDescendantOf(head.Parent)
end

local function fireAutoRMB(now)
    lastRMBClick = now
    local ok, err = pcall(clickRMB)
    if not ok then
        autoRMBEnabled = false
        notice("Auto RMB failed: " .. tostring(err))
    end
end

local function updateCursorRMB()
    if lockEnabled or not autoRMBEnabled or not clickRMB then return end
    local now = os.clock()
    if now - lastRMBClick < rmbClickInterval then return end
    if not gameFocused then return end
    if UserInputService:GetFocusedTextBox() then return end
    local camera = workspace.CurrentCamera
    if not camera then return end
    local cursor = UserInputService:GetMouseLocation()
    local viewport = camera.ViewportSize
    if cursor.X < 0 or cursor.Y < 0 or cursor.X >= viewport.X or cursor.Y >= viewport.Y then return end
    local ray = camera:ViewportPointToRay(cursor.X, cursor.Y)
    local localCharacter = Players.LocalPlayer.Character
    visibilityParams.FilterDescendantsInstances = localCharacter and { localCharacter } or {}
    local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, visibilityParams)
    local part = hit and hit.Instance
    if not part or not part:IsA("BasePart") or part.Transparency >= 1
        or part.LocalTransparencyModifier >= 1 then return end
    local character = part.Parent
    if not character or not character:IsA("Model") then return end
    local player = Players:GetPlayerFromCharacter(character)
    if not player or player == Players.LocalPlayer then return end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return end
    if not hasClearThrowPath(getThrowOrigin(camera), hit.Position, part) then return end
    fireAutoRMB(now)
end

local function tryAutoRMB(camera, head, aimPoint, throwOrigin)
    if not lockEnabled or not autoRMBEnabled or not clickRMB then
        return
    end
    local now = os.clock()
    if now - lastRMBClick < rmbClickInterval or not isHeadVisible(camera, head) then
        return
    end
    if not hasClearThrowPath(throwOrigin, aimPoint, head) then
        return
    end
    local direction = aimPoint - camera.CFrame.Position
    if direction.Magnitude < 0.001
        or camera.CFrame.LookVector:Dot(direction.Unit) < math.cos(math.rad(1.5)) then
        return
    end

    fireAutoRMB(now)
end

local function updatePlayerLock(deltaTime)
    diagnostics.lockTicks = diagnostics.lockTicks + 1
    if not gameFocused then return end
    local camera = workspace.CurrentCamera
    if not camera then
        return
    end

    local target = findFOVTarget(camera)
    if not target then
        return
    end

    local position = camera.CFrame.Position
    local throwOrigin = getThrowOrigin(camera)
    local preparingThrow = autoRMBEnabled
        or UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
    local aimPoint = target.Position
    if preparingThrow then
        if throwPrediction then
            aimPoint = predictThrow(throwOrigin, target)
        end
        if not aimPoint or not isHeadVisible(camera, target)
            or not hasClearThrowPath(throwOrigin, aimPoint, target) then
            return
        end
    end
    if (aimPoint - position).Magnitude > 0.001 then
        local targetCFrame = CFrame.lookAt(position, aimPoint)
        local alpha = 1
        if aimSmoothness > 0 then
            local responseTime = aimSmoothness / 200
            alpha = 1 - math.exp(-math.max(deltaTime, 0) / responseTime)
        end
        camera.CFrame = camera.CFrame:Lerp(targetCFrame, alpha)
        tryAutoRMB(camera, target, aimPoint, throwOrigin)
    end
end

local function setPlayerLock(enabled)
    if lockEnabled == enabled then
        return
    end
    lockEnabled = enabled
    if enabled then
        RunService:BindToRenderStep(lockBinding, Enum.RenderPriority.Camera.Value + 1, function(deltaTime)
            local ok, err = pcall(updatePlayerLock, deltaTime)
            if not ok then
                lockEnabled = false
                RunService:UnbindFromRenderStep(lockBinding)
                diagnostics.error = "Lock: " .. tostring(err)
                notice(diagnostics.error)
            end
        end)
    else
        RunService:UnbindFromRenderStep(lockBinding)
    end
end


local configFolder = "GameSenseExternal"
local autoLoadPath = configFolder .. "/_autoload.txt"
local configName = "default"
local savedNames = {}
local configAvailable = type(writefile) == "function" and type(readfile) == "function"
    and type(isfile) == "function" and type(isfolder) == "function"
    and type(makefolder) == "function" and type(listfiles) == "function"

local function validConfigName(name)
    return type(name) == "string" and #name > 0 and #name <= 48
        and name:match("%S") ~= nil and name:match("^[%w_%- ]+$") ~= nil
end

local function parseLockKey(name)
    if type(name) ~= "string" then return nil end
    local ok, key = pcall(function() return Enum.KeyCode[name] end)
    if ok and key and key ~= Enum.KeyCode.Unknown and key ~= Enum.KeyCode.K
        and key ~= Enum.KeyCode.End then return key end
    return nil
end

local function settingsSnapshot()
    return {
        Version = 1, ESP = espEnabled, AimLock = lockEnabled, ShowFOV = showFOV,
        FOVRadius = fovRadius, AimSmoothness = aimSmoothness,
        ThrowPrediction = throwPrediction, KnifeSpeed = knifeSpeed,
        AutoRMB = autoRMBEnabled, AimLockKey = lockKey.Name,
    }
end

local function applySettings(data)
    assert(type(data) == "table" and data.Version == 1, "Unsupported external config format")
    for _, key in ipairs({ "ESP", "AimLock", "ShowFOV", "ThrowPrediction", "AutoRMB" }) do
        assert(type(data[key]) == "boolean", "Invalid config field: " .. key)
    end
    for _, key in ipairs({ "FOVRadius", "AimSmoothness", "KnifeSpeed" }) do
        local value = data[key]
        assert(type(value) == "number" and value == value and math.abs(value) < math.huge,
            "Invalid config field: " .. key)
    end
    local key = parseLockKey(data.AimLockKey)
    assert(key, "Invalid aimlock key (K and End are reserved)")
    fovRadius = math.clamp(data.FOVRadius, 25, 500)
    aimSmoothness = math.clamp(data.AimSmoothness, 0, 100)
    knifeSpeed = math.clamp(data.KnifeSpeed, 25, 1000)
    showFOV, throwPrediction = data.ShowFOV, data.ThrowPrediction
    autoRMBEnabled = data.AutoRMB and clickRMB ~= nil
    lockKey = key
    setESP(data.ESP)
    setPlayerLock(data.AimLock)
    requestMenuRefresh()
end

local function refreshConfigs()
    savedNames = {}
    for _, path in ipairs(listfiles(configFolder)) do
        local name = path:gsub("\\", "/"):match("([^/]+)%.json$")
        if name and validConfigName(name) then table.insert(savedNames, name) end
    end
    table.sort(savedNames)
end

local function configAction(action)
    local ok, err = pcall(function()
        assert(configAvailable, "Executor file APIs are unavailable")
        if not isfolder(configFolder) then makefolder(configFolder) end
        if action == "Refresh" then
            refreshConfigs()
        elseif action == "DisableAuto" then
            writefile(autoLoadPath, "")
        else
            assert(validConfigName(configName), "Use 1-48 letters, numbers, spaces, underscores or hyphens")
            local path = configFolder .. "/" .. configName .. ".json"
            if action == "Save" then
                writefile(path, HttpService:JSONEncode(settingsSnapshot()))
                refreshConfigs()
            elseif action == "Load" then
                assert(isfile(path), "Config does not exist: " .. configName)
                applySettings(HttpService:JSONDecode(readfile(path)))
            elseif action == "Auto" then
                assert(isfile(path), "Save this config before enabling auto-load")
                writefile(autoLoadPath, configName)
            end
        end
    end)
    notice(ok and (action .. " completed") or (action .. " failed: " .. tostring(err)))
end

local controller = {}
function controller.Unload()
    if not running then return end
    running = false
    menuGeneration = menuGeneration + 1
    RunService:UnbindFromRenderStep(lockBinding)
    RunService:UnbindFromRenderStep(overlayBinding)
    for _, connection in ipairs(connections) do connection:Disconnect() end
    if window then pcall(function() window:destroy() end); window = nil end
    for object in pairs(drawings) do removeDrawing(object) end
    table.clear(playerBoxes)
    table.clear(trackedPlayers)
    table.clear(boundsCache)
    if environment.GameSenseOverlay == controller then environment.GameSenseOverlay = nil end
end
environment.GameSenseOverlay = controller
function controller.Status()
    local playersCount, boxesCount = 0, 0
    for _ in pairs(trackedPlayers) do playersCount = playersCount + 1 end
    for _ in pairs(playerBoxes) do boxesCount = boxesCount + 1 end
    return string.format("ESP=%s FOV=%s Lock=%s RMB=%s | Focus=%s Camera=%s | Players=%d Boxes=%d | Render=%d LockTicks=%d Controls=%d | Error: %s",
        tostring(espEnabled), tostring(showFOV), tostring(lockEnabled), tostring(autoRMBEnabled),
        tostring(gameFocused), tostring(workspace.CurrentCamera ~= nil), playersCount, boxesCount,
        diagnostics.overlayTicks, diagnostics.lockTicks, diagnostics.callbacks, diagnostics.error)
end

rebuildMenu = function()
    menuGeneration = menuGeneration + 1
    local generation = menuGeneration
    if window then window:destroy(); window = nil end
    if not running or not menuVisible then return end
    window = imgui.create("GameSense.exe")
    local function callback(fn)
        return function(...)
            if running and generation == menuGeneration then
                diagnostics.callbacks = diagnostics.callbacks + 1
                local ok, err = pcall(fn, ...)
                if not ok then
                    diagnostics.error = "Control: " .. tostring(err)
                    notice(diagnostics.error)
                end
            end
        end
    end
    window:Text("K: menu | " .. lockKey.Name .. ": lock | End: unload")
    window:Text(noticeText)
    window:Button("Show status", callback(function() notice(controller.Status()) end))
    window:Separator()
    window:Checkbox("ESP boxes", espEnabled, callback(setESP))
    window:Checkbox("Show FOV", showFOV, callback(function(value) showFOV = value end))
    window:SliderInt("FOV radius", math.floor(fovRadius), 25, 500, callback(function(value)
        fovRadius = math.clamp(value, 25, 500)
    end))
    window:Separator()
    window:Checkbox("Lock On", lockEnabled, callback(setPlayerLock))
    window:InputText("Aimlock key (Enum name)", lockKey.Name, callback(function(value)
        local key = parseLockKey(value)
        if key then lockKey = key end
    end))
    window:Text("Key example: Q, E, F2, LeftAlt. K and End are reserved.")
    window:SliderInt("Smoothness", math.floor(aimSmoothness), 0, 100, callback(function(value)
        aimSmoothness = math.clamp(value, 0, 100)
    end))
    window:Checkbox("Throw prediction", throwPrediction, callback(function(value) throwPrediction = value end))
    window:SliderInt("Knife speed", math.floor(knifeSpeed), 25, 1000, callback(function(value)
        knifeSpeed = math.clamp(value, 25, 1000)
    end))
    if clickRMB then
        window:Checkbox("Auto RMB", autoRMBEnabled, callback(function(value) autoRMBEnabled = value end))
        window:Text("Unlocked: throws over a player's body. Locked: throws when aim aligns.")
    else
        window:Text("Auto RMB unavailable: mouse2click is missing.")
    end
    window:Separator()
    window:InputText("Config name", configName, callback(function(value)
        configName = value:match("^%s*(.-)%s*$")
    end))
    window:Button("Save config", callback(function() configAction("Save") end))
    window:Button("Load config", callback(function() configAction("Load") end))
    window:Button("Refresh configs", callback(function() configAction("Refresh") end))
    for _, name in ipairs(savedNames) do
        window:Button("Select: " .. name, callback(function()
            configName = name
            requestMenuRefresh()
        end))
    end
    window:Button("Auto-load this config", callback(function() configAction("Auto") end))
    window:Button("Disable auto-load", callback(function() configAction("DisableAuto") end))
    window:Separator()
    window:Button("Unload", callback(function() task.defer(controller.Unload) end))
end

local ok, err = pcall(function()
    table.insert(connections, UserInputService.WindowFocused:Connect(function() gameFocused = true end))
    table.insert(connections, UserInputService.WindowFocusReleased:Connect(function() gameFocused = false end))
    table.insert(connections, Players.PlayerAdded:Connect(trackPlayer))
    table.insert(connections, Players.PlayerRemoving:Connect(removePlayer))
    for _, player in ipairs(Players:GetPlayers()) do trackPlayer(player) end
    if configAvailable then
        local loaded, loadError = pcall(function()
            if not isfolder(configFolder) then makefolder(configFolder) end
            refreshConfigs()
            if isfile(autoLoadPath) then
                local name = readfile(autoLoadPath):match("^%s*(.-)%s*$")
                if name ~= "" then
                    assert(validConfigName(name), "Invalid startup config name")
                    configName = name
                    applySettings(HttpService:JSONDecode(readfile(configFolder .. "/" .. name .. ".json")))
                end
            end
        end)
        if not loaded then notice("Auto-load failed: " .. tostring(loadError)) end
    end
    rebuildMenu()
    table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        if input.KeyCode == Enum.KeyCode.End then controller.Unload(); return end
        if processed or UserInputService:GetFocusedTextBox() then return end
        if not gameFocused then return end
        if input.KeyCode == Enum.KeyCode.K then
            menuVisible = not menuVisible
            rebuildMenu()
        elseif input.KeyCode == lockKey then
            setPlayerLock(not lockEnabled)
            requestMenuRefresh()
        end
    end))
    RunService:BindToRenderStep(overlayBinding, Enum.RenderPriority.Last.Value, function(deltaTime)
        overlayElapsed = overlayElapsed + deltaTime
        if overlayElapsed < overlayInterval then return end
        overlayElapsed = overlayElapsed % overlayInterval
        diagnostics.overlayTicks = diagnostics.overlayTicks + 1
        local rendered, renderError = true, nil
        if drawingHealthy then rendered, renderError = pcall(updateOverlay) end
        if not rendered then
            drawingHealthy = false
            espEnabled, showFOV = false, false
            for object in pairs(drawings) do removeDrawing(object) end
            table.clear(playerBoxes)
            diagnostics.error = "Drawing: " .. tostring(renderError)
            notice(diagnostics.error)
        end
        local triggered, triggerError = pcall(updateCursorRMB)
        if not triggered then
            autoRMBEnabled = false
            diagnostics.error = "Auto RMB: " .. tostring(triggerError)
            notice(diagnostics.error)
        end
    end)
end)
if not ok then
    controller.Unload()
    error("GameSense.exe startup failed: " .. tostring(err), 0)
end
