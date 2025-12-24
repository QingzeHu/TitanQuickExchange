-- TitanQuickExchange.lua
-- ✅ 勾选状态持久（不被购买/刷新重置）
-- ✅ 默认模式：右键一次买满 1 个堆叠组（stackSize）
-- ✅ 高级模式：输入目标个数（可为空），后台固定 1s 节流执行
-- ✅ 悬停显示当前条目：name / stackSize / perPurchase / 预测
-- ✅ UI 不显示节流提示
-- ✅ Log 更清晰：分开“堆数/兑换次数/每次兑换给多少”
local ADDON_NAME = "TitanQuickExchange"
local FIXED_INTERVAL = 1.0
local MAX_ACTIONS = 500

-- -----------------------
-- DB (只初始化一次，不强制重置)
-- -----------------------
local function InitDBOnce()
    if type(TQE_DB) ~= "table" then
        TQE_DB = {}
    end
    if TQE_DB.fastEnabled == nil then
        TQE_DB.fastEnabled = false
    end
    if TQE_DB.advEnabled == nil then
        TQE_DB.advEnabled = false
    end
    -- 允许 nil：表示用户没填，不给默认
    if TQE_DB.targetCount ~= nil then
        local n = tonumber(TQE_DB.targetCount)
        if not n or n < 1 then
            TQE_DB.targetCount = nil
        end
    end
end

local function ClampInt(v, minV, maxV, fallback)
    v = tonumber(v)
    if not v then
        return fallback
    end
    v = math.floor(v)
    if v < minV then
        v = minV
    end
    if v > maxV then
        v = maxV
    end
    return v
end

local function CeilDiv(a, b)
    return math.floor((a + b - 1) / b)
end

-- -----------------------
-- Merchant helpers
-- -----------------------
local function GetOffset()
    if MerchantFrame and MerchantFrame.itemOffset then
        return MerchantFrame.itemOffset
    end
    if MerchantFrame_GetOffset then
        return MerchantFrame_GetOffset()
    end
    if MerchantFrame and MerchantFrame.page then
        return (MerchantFrame.page - 1) * (MERCHANT_ITEMS_PER_PAGE or 12)
    end
    return 0
end

local function GetPerPurchase(index)
    local q = select(4, GetMerchantItemInfo(index))
    if type(q) ~= "number" or q < 1 then
        return 1
    end
    return q
end

local function GetItemLink(index)
    return GetMerchantItemLink and GetMerchantItemLink(index) or nil
end

local function GetStackSizeFromLink(itemLink)
    if not itemLink or not GetItemInfo then
        return nil
    end
    local stackCount = select(8, GetItemInfo(itemLink))
    if type(stackCount) ~= "number" or stackCount < 1 then
        return nil
    end
    return stackCount
end

-- -----------------------
-- Hover tracking
-- -----------------------
local Hover = {
    index = nil,
    name = nil,
    perPurchase = nil,
    stackSize = nil,
    link = nil
}

local function UpdateHover(index)
    Hover.index = index
    Hover.link = GetItemLink(index)
    Hover.stackSize = GetStackSizeFromLink(Hover.link) -- may be nil until cached
    Hover.perPurchase = GetPerPurchase(index)
    Hover.name = (select(1, GetMerchantItemInfo(index))) or "?"
end

local function ClearHover()
    Hover.index = nil;
    Hover.name = nil;
    Hover.perPurchase = nil;
    Hover.stackSize = nil;
    Hover.link = nil
end

local function HookHoverButtons()
    local perPage = MERCHANT_ITEMS_PER_PAGE or 12
    for i = 1, perPage do
        local a = _G["MerchantItem" .. i]
        local b = _G["MerchantItem" .. i .. "ItemButton"]

        local function attach(frame)
            if not frame or frame.__TQE_HoverHooked then
                return
            end
            frame.__TQE_HoverHooked = true
            frame:HookScript("OnEnter", function(self)
                local id = (self.GetID and self:GetID()) or i
                local idx = GetOffset() + id
                if idx > 0 then
                    UpdateHover(idx)
                end
            end)
        end

        attach(a);
        attach(b)
    end
end

-- -----------------------
-- Job queue (固定 1s)
-- -----------------------
local Job = {
    token = 0,
    running = false,
    actions = nil,
    desc = nil
}

local function CancelJob()
    Job.token = Job.token + 1
    Job.running = false
    Job.actions = nil
    Job.desc = nil
end

local function StartJob(actions, desc)
    CancelJob()
    Job.token = Job.token + 1
    local token = Job.token
    Job.running = true
    Job.actions = actions
    Job.desc = desc

    local total = #actions
    local done = 0

    local function step()
        if token ~= Job.token then
            return
        end
        if not Job.running or not Job.actions then
            return
        end

        if done >= total then
            Job.running = false
            print(("|cff00ff00[TQE]|r 完成：%s"):format(desc or "任务"))
            return
        end

        done = done + 1
        local fn = Job.actions[done]
        if fn then
            fn()
        end

        if done < total then
            if C_Timer and C_Timer.After then
                C_Timer.After(FIXED_INTERVAL, step)
            else
                step()
            end
        else
            step()
        end
    end

    print(("|cff00ff00[TQE]|r 开始：%s"):format(desc or "任务"))
    step()
end

-- -----------------------
-- Log formatting (关键：不混淆“堆/兑换次数/最小单位”)
-- -----------------------
local function BuildPlanLog(name, targetCount, stackSize, perPurchase, fullStacks, remainder, totalPurchases,
    tailPurchases, tailActual)
    local planPart = ("计划：%d堆 + 尾单%d个"):format(fullStacks, remainder)
    local stackPart = ("堆叠%d/堆"):format(stackSize)

    local exchangePart
    if perPurchase == 1 then
        exchangePart = ("兑换次数：%d次(每次1个)"):format(totalPurchases)
    else
        exchangePart = ("兑换次数：%d次(每次%d个)"):format(totalPurchases, perPurchase)
    end

    local tailPart = ""
    if remainder > 0 then
        if perPurchase == 1 then
            tailPart = (" | 尾单需要：%d次=实际%d个"):format(remainder, remainder)
        else
            tailPart = (" | 尾单需要：%d次=实际%d个"):format(tailPurchases, tailActual)
        end
    end

    return ("%s 目标%d个 | %s | %s | %s%s"):format(name, targetCount, stackPart, planPart, exchangePart, tailPart)
end

-- -----------------------
-- Planning logic
-- -----------------------
local function PlanBuyExactCount(index, targetCount)
    targetCount = ClampInt(targetCount, 1, 1000000, nil)
    if not targetCount then
        return nil, "高级模式需要先输入目标个数"
    end

    local perPurchase = GetPerPurchase(index)
    local link = GetItemLink(index)
    local stackSize = GetStackSizeFromLink(link)
    local name = (select(1, GetMerchantItemInfo(index))) or "?"

    if not stackSize then
        -- item info 未缓存时：退化处理（仍可用）
        stackSize = perPurchase
    end

    local fullStacks = math.floor(targetCount / stackSize)
    local remainder = targetCount % stackSize

    local actions = {}
    local totalPurchases = 0
    local tailPurchases = 0
    local tailActual = 0

    local function pushBuy(qty, isTail)
        if #actions >= MAX_ACTIONS then
            return
        end

        if perPurchase == 1 then
            -- 这里一次 action 就能请求 qty
            table.insert(actions, function()
                ClearCursor()
                BuyMerchantItem(index, qty)
            end)
            totalPurchases = totalPurchases + qty
            if isTail then
                tailPurchases = qty
                tailActual = qty
            end
        else
            local purchases = CeilDiv(qty, perPurchase)
            for _ = 1, purchases do
                if #actions >= MAX_ACTIONS then
                    return
                end
                table.insert(actions, function()
                    ClearCursor()
                    BuyMerchantItem(index, 1)
                end)
            end
            totalPurchases = totalPurchases + purchases
            if isTail then
                tailPurchases = purchases
                tailActual = purchases * perPurchase
            end
        end
    end

    for _ = 1, fullStacks do
        pushBuy(stackSize, false)
    end
    if remainder > 0 then
        pushBuy(remainder, true)
    end

    if #actions == 0 then
        return nil, "无法生成购买步骤"
    end
    if #actions >= MAX_ACTIONS then
        return nil, ("步骤过多（>%d），请把目标个数调小"):format(MAX_ACTIONS)
    end

    local desc = BuildPlanLog(name, targetCount, stackSize, perPurchase, fullStacks, remainder, totalPurchases,
        tailPurchases, tailActual)
    return actions, desc
end

local function PlanBuyOneStack(index)
    local perPurchase = GetPerPurchase(index)
    local link = GetItemLink(index)
    local stackSize = GetStackSizeFromLink(link)
    local name = (select(1, GetMerchantItemInfo(index))) or "?"

    if not stackSize then
        stackSize = perPurchase
    end

    local actions, descOrErr = PlanBuyExactCount(index, stackSize)
    if not actions then
        return nil, descOrErr
    end

    -- 默认模式：把 log 改得更直观
    local fullStacks = 1
    local remainder = 0
    local totalPurchases
    if perPurchase == 1 then
        totalPurchases = stackSize
    else
        totalPurchases = CeilDiv(stackSize, perPurchase)
    end
    local desc = ("%s 购买1组 | 堆叠%d/堆 | 兑换次数：%d次(每次%d个)"):format(name, stackSize,
        totalPurchases, perPurchase)
    return actions, desc
end

-- -----------------------
-- Right-click hook
-- -----------------------
local function InstallHook()
    if _G.__TQE_Installed then
        return
    end
    if type(_G.MerchantItemButton_OnClick) ~= "function" then
        return
    end
    _G.__TQE_Installed = true

    local orig = _G.MerchantItemButton_OnClick

    _G.MerchantItemButton_OnClick = function(self, mouseButton)
        if mouseButton ~= "RightButton" then
            return orig(self, mouseButton)
        end

        if not TQE_DB.fastEnabled and not TQE_DB.advEnabled then
            return orig(self, mouseButton)
        end

        local visibleID = self and self.GetID and self:GetID() or 0
        if visibleID <= 0 then
            return orig(self, mouseButton)
        end

        local index = GetOffset() + visibleID

        if TQE_DB.advEnabled then
            local actions, descOrErr = PlanBuyExactCount(index, TQE_DB.targetCount)
            if not actions then
                print("|cffff0000[TQE]|r " .. tostring(descOrErr))
                return
            end
            StartJob(actions, descOrErr)
            return
        end

        if TQE_DB.fastEnabled then
            local actions, descOrErr = PlanBuyOneStack(index)
            if not actions then
                print("|cffff0000[TQE]|r " .. tostring(descOrErr))
                return
            end
            StartJob(actions, descOrErr)
            return
        end

        return orig(self, mouseButton)
    end
end

-- -----------------------
-- UI
-- -----------------------
local function CreateUI()
    if _G.TQE_Panel or not MerchantFrame then
        return
    end

    local panel = CreateFrame("Frame", "TQE_Panel", MerchantFrame, "BackdropTemplate")
    panel:SetSize(340, 160)
    panel:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 8, -28)
    panel:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = {
            left = 3,
            right = 3,
            top = 3,
            bottom = 3
        }
    })
    panel:SetBackdropColor(0, 0, 0, 0.85)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("TQE 快速兑换")

    -- Default checkbox
    local fastCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    fastCB:SetPoint("TOPLEFT", 10, -35)
    local fastText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fastText:SetPoint("LEFT", fastCB, "RIGHT", 4, 0)
    fastText:SetText("默认：右键一次买 1 组（堆叠）")

    fastCB:SetScript("OnClick", function(self)
        TQE_DB.fastEnabled = self:GetChecked() and true or false
        if TQE_DB.fastEnabled then
            TQE_DB.advEnabled = false
        end
        panel:Refresh()
    end)

    -- Advanced checkbox
    local advCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    advCB:SetPoint("TOPLEFT", 10, -60)
    local advText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    advText:SetPoint("LEFT", advCB, "RIGHT", 4, 0)
    advText:SetText("高级：按目标个数购买")

    advCB:SetScript("OnClick", function(self)
        TQE_DB.advEnabled = self:GetChecked() and true or false
        if TQE_DB.advEnabled then
            TQE_DB.fastEnabled = false
        end
        panel:Refresh()
    end)

    -- Advanced input (empty by default)
    local advBox = CreateFrame("Frame", nil, panel)
    advBox:SetPoint("TOPLEFT", 10, -86)
    advBox:SetSize(320, 22)

    local advLabel = advBox:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    advLabel:SetPoint("LEFT", 0, 0)
    advLabel:SetText("目标个数：")

    local advEdit = CreateFrame("EditBox", nil, advBox, "InputBoxTemplate")
    advEdit:SetSize(90, 18)
    advEdit:SetPoint("LEFT", advLabel, "RIGHT", 6, 0)
    advEdit:SetAutoFocus(false)
    advEdit:SetNumeric(true)
    advEdit.__internal = false
    advEdit.__editing = false

    advEdit:SetScript("OnEditFocusGained", function(self)
        self.__editing = true
    end)
    advEdit:SetScript("OnEditFocusLost", function(self)
        self.__editing = false
    end)

    advEdit:SetScript("OnTextChanged", function(self, userInput)
        if self.__internal or not userInput then
            return
        end
        local txt = self:GetText()
        if not txt or txt == "" then
            TQE_DB.targetCount = nil
            return
        end
        local v = tonumber(txt)
        if not v or v < 1 then
            TQE_DB.targetCount = nil
            return
        end
        TQE_DB.targetCount = math.floor(v)
    end)

    -- Hover info
    local hoverText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hoverText:SetPoint("TOPLEFT", 10, -114)
    hoverText:SetJustifyH("LEFT")
    hoverText:SetText("鼠标指向：无")

    local function setEditTextOrEmpty(v)
        advEdit.__internal = true
        if v == nil then
            advEdit:SetText("")
        else
            advEdit:SetText(tostring(v))
        end
        advEdit.__internal = false
    end

    panel.Refresh = function()
        fastCB:SetChecked(TQE_DB.fastEnabled and true or false)
        advCB:SetChecked(TQE_DB.advEnabled and true or false)

        advBox:SetShown(TQE_DB.advEnabled and true or false)
        if not advEdit.__editing then
            setEditTextOrEmpty(TQE_DB.targetCount)
        end

        if Hover.index then
            Hover.link = Hover.link or GetItemLink(Hover.index)
            Hover.stackSize = GetStackSizeFromLink(Hover.link) or Hover.stackSize
            Hover.perPurchase = GetPerPurchase(Hover.index)
            Hover.name = (select(1, GetMerchantItemInfo(Hover.index))) or Hover.name or "?"

            local stackSize = Hover.stackSize or "?"
            local per = Hover.perPurchase or "?"
            local line1 = ("鼠标指向：%s"):format(tostring(Hover.name))
            local line2 = ("堆叠上限：%s    每次最少兑换：%s"):format(tostring(stackSize), tostring(per))

            local extra = ""

            if type(stackSize) == "number" and type(per) == "number" then
                -- ✅ 只有默认模式开启时，才显示“右键一次≈...”
                if TQE_DB.fastEnabled and not TQE_DB.advEnabled then
                    local pps = math.ceil(stackSize / per)
                    local predicted = pps * per
                    if per == 1 then
                        extra = ("\n默认模式：右键一次=%d个"):format(stackSize)
                    else
                        extra = ("\n默认模式：右键一次=%d个（受最小兑换单位影响）"):format(
                            predicted)
                    end
                end

                -- ✅ 高级模式开启时，不显示右键提示（避免误导）
                -- 你如果想显示“当前目标个数”，可以用下面这段（可选）
                if TQE_DB.advEnabled then
                    if TQE_DB.targetCount then
                        extra = ("\n高级模式：目标=%d个（右键开始执行）"):format(tonumber(
                            TQE_DB.targetCount))
                    else
                        extra = "\n高级模式：未填写目标个数"
                    end
                end
            else
                extra = "\n（物品信息未缓存，稍等会显示堆叠上限）"
            end

            hoverText:SetText(line1 .. "\n" .. line2 .. extra)
        else
            hoverText:SetText("鼠标指向：无\n（把鼠标放到商人物品上显示详情）")
        end
    end

    _G.TQE_Panel = panel

    hooksecurefunc("MerchantFrame_Update", function()
        if MerchantFrame and MerchantFrame:IsShown() then
            panel:Show()
            HookHoverButtons()
            panel:Refresh()
        else
            panel:Hide()
            ClearHover()
        end
    end)

    panel:SetScript("OnUpdate", function(self, elapsed)
        self.__acc = (self.__acc or 0) + elapsed
        if self.__acc >= 0.10 then
            self.__acc = 0
            if self:IsShown() then
                local perPage = MERCHANT_ITEMS_PER_PAGE or 12
                local anyOver = false
                for i = 1, perPage do
                    local a = _G["MerchantItem" .. i]
                    local b = _G["MerchantItem" .. i .. "ItemButton"]
                    if (a and a:IsShown() and a:IsMouseOver()) or (b and b:IsShown() and b:IsMouseOver()) then
                        anyOver = true
                        break
                    end
                end
                if not anyOver then
                    ClearHover()
                end
                self:Refresh()
            end
        end
    end)
end

-- -----------------------
-- Entry
-- -----------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("MERCHANT_UPDATE")

f:SetScript("OnEvent", function(_, event, addonName)
    if event == "ADDON_LOADED" then
        if addonName ~= ADDON_NAME then
            return
        end
        InitDBOnce()
        InstallHook()
        CreateUI()
        return
    end

    -- 商人事件：只刷新 UI，不动 DB
    if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
        if not _G.TQE_Panel then
            CreateUI()
        end
        if _G.TQE_Panel and MerchantFrame and MerchantFrame:IsShown() then
            _G.TQE_Panel:Show()
            HookHoverButtons()
            _G.TQE_Panel:Refresh()
        end
    end
end)
