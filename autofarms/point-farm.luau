local script_to_run = [[loadstring(game:HttpGet("https://raw.githubusercontent.com/jojosbytes/AutoFarm/refs/heads/main/KohauFarm.lua"))()]]

if syn and syn.queue_on_teleport then
	syn.queue_on_teleport(script_to_run)
elseif queue_on_teleport then
	queue_on_teleport(script_to_run)
end

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Players = game:GetService('Players')
local HttpService = game:GetService('HttpService')

local Player = Players.LocalPlayer
local Character = Player.Character or Player.CharacterAdded:Wait()
local Backpack = Player:WaitForChild('Backpack')

local OJFramework = ReplicatedStorage:FindFirstChild('OJFramework')

local Modules = OJFramework:WaitForChild("Modules")
local Network = Modules:WaitForChild('5 | Network')

local Events = Network:WaitForChild('Remotes'):FindFirstChild('Events')
local Functions = Network:WaitForChild('Remotes'):FindFirstChild('Functions')
local Postie = OJFramework:WaitForChild("Packages"):WaitForChild("Postie")

local RecivedRemote = Postie:WaitForChild("Received")
local SentRemote = Postie:WaitForChild("Sent")

local ProgrammedHolder = workspace:WaitForChild("programmed_holder")
local CookingFolder = ProgrammedHolder:FindFirstChild('Cooking')
local TeleportService = game:GetService("TeleportService")

local PLACE_ID = game.PlaceId

local wt = 0.1

local fridge = nil

local Teams = game:GetService("Teams")

local CanFarm = true

local function SetUpScript()
	local calc = Vector3.new(-111, 3, -434)

	Character:MoveTo(calc)

	wait()

	local closest = nil
	local closestDist = math.huge

	for _, fridge in ipairs(CookingFolder.Fridges:GetChildren()) do
		if fridge.Name == "Fridge" then
			local pos = fridge:GetPivot().Position
			local dist = (Character:FindFirstChild('HumanoidRootPart').Position - pos).Magnitude

			if dist < closestDist then
				closestDist = dist
				closest = fridge
			end
		end
	end

	if closest ~= nil then
		fridge = closest

		local pos = fridge:GetPivot()
		Character:PivotTo(pos)
	end
end

local function EquipAllCoffee()
	for i,v in pairs(Backpack:GetChildren()) do
		if v:IsA("Tool") and v.Name == "Coffee" then
			v.Parent = Character
		end
	end
end

local function GetServers(cursor)
	local url = "https://games.roblox.com/v1/games/"..PLACE_ID.."/servers/Public?sortOrder=Asc&limit=100"
	if cursor then
		url = url .. "&cursor=" .. cursor
	end

	local success, result = pcall(function()
		return game:HttpGet(url)
	end)

	if not success or not result then
		return nil
	end

	local decodeSuccess, decoded = pcall(function()
		return HttpService:JSONDecode(result)
	end)

	if not decodeSuccess then
		return nil
	end

	return decoded
end

local function FindLowestServer()
	local lowestServer = nil
	local cursor = nil

	repeat
		local data = GetServers(cursor)
		if not data or not data.data then break end

		for _, server in ipairs(data.data) do
			if server.id ~= game.JobId and server.playing < server.maxPlayers then
				if not lowestServer or server.playing < lowestServer.playing then
					lowestServer = server
				end
			end
		end

		cursor = data.nextPageCursor
	until not cursor

	return lowestServer
end

local function HopToLowest()
	local server = FindLowestServer()
	if server then
		TeleportService:TeleportToPlaceInstance(PLACE_ID, server.id, Player)
	else
		TeleportService:Teleport(PLACE_ID, Player)
	end
end

local function GetExecutiveCount()
	for _, team in ipairs(Teams:GetTeams()) do
		if team.Name == "🌸 Executives" then
			return #team:GetPlayers()
		end
	end
	warn("Executives team not found")
	return 0
end

if GetExecutiveCount() ~= 0 then
	HopToLowest()
	return
end

wait(2)

local function GetDrink()

	local originaltools = {}

	for i,v in pairs(Character:GetChildren()) do
		if v:IsA("Tool") then
			table.insert(originaltools, v)
		end
	end

	local args = {
		fridge:WaitForChild("Interaction")
	}
	Events:WaitForChild("FridgeItemSelected"):FireServer(unpack(args))

	local args = {
		fridge,
		"Coffee"
	}
	Functions:WaitForChild("TakeDrink"):InvokeServer(unpack(args))

	task.delay(0.01,function()
		for i,v in pairs(originaltools) do
			v.Parent = Character
		end
	end)
end

local function DisableUILag()
	local Noti = Player.PlayerGui.UserInterface.Main.Phone.Notifications

	Noti.ChildAdded:Connect(function(child)
		if child:IsA("Frame") then
			child:Destroy()
		end
	end)
end

local function HandDrink()
	EquipAllCoffee()

	local args = {game:GetService("Players").LocalPlayer,false}
	Events:WaitForChild("HandTo"):FireServer(unpack(args))
end

local function AcceptTool(guid)
	local args = {guid,true,"Yes"}
	RecivedRemote:FireServer(unpack(args))
end

local cd = false
local function RemoveAllTool()

	if cd == false then cd = true
		local args = {
			"all"
		}
		Events:WaitForChild("DestroyTool"):FireServer(unpack(args))

		wait(1)
		cd = false
	end
end

SentRemote.OnClientEvent:Connect(function(...)
	local args = {...}

	local guid = args[2] 

	AcceptTool(guid)
	task.wait()
	RemoveAllTool()
end)

local function CheckPlayerCount()
	local AmountOfPlayers = #game.Players:GetPlayers()

	if AmountOfPlayers > 10 then
		HopToLowest()

		return true
	else
		return false
	end
end

SetUpScript()

repeat wait() until fridge ~= nil

task.spawn(function()
	Character.ChildAdded:Connect(function(child)
		HandDrink()
	end)

	task.spawn(function()
		while true do
			task.wait(25)
			wt = 5
			task.wait(1)
			wt = 0.1
		end
	end)

	while true do
		task.wait(wt)

		if GetExecutiveCount() ~= 0 then
			HopToLowest()
		end

		GetDrink()
		EquipAllCoffee()
	end
end)

spawn(DisableUILag)

wait(500)

HopToLowest()
