local ADDON = ...
local VERSION = '0.6.12'
local F = CreateFrame('Frame')
local DB
local UI
local rows = {}
local priceCache = {}
local craftingIndexDirty=true
local resultsDirty=true
local cachedResults
local dependencyWarnings={}
local function invalidateRecipes()
  craftingIndexDirty=true
  resultsDirty=true
  cachedResults=nil
end
local function invalidatePrices()
  priceCache={}
  resultsDirty=true
  cachedResults=nil
end
local function dependencyState()
  local a=_G.Auctionator
  local auction=type(a)=='table' and type(a.Database)=='table' and type(a.Database.GetPrice)=='function'
  local synd=type(_G.Syndicator)=='table' and type(_G.Syndicator.API)=='table' and type(_G.Syndicator.API.GetCurrentCharacter)=='function'
  local scanner=type(_G.PriceScannerDB)=='table' and type(_G.PriceScannerDB.vendor)=='table'
  return auction,synd,scanner
end
local function checkDependencies()
  local auction,synd,scanner=dependencyState()
  local problems={}
  if not auction then problems[#problems+1]='Auctionator fehlt, ist deaktiviert oder seine Preis-API ist nicht verfuegbar.' end
  if not synd then problems[#problems+1]='Syndicator fehlt, ist deaktiviert oder seine Inventar-API ist nicht verfuegbar.' end
  if not scanner then problems[#problems+1]='Price Scanner Forever: Haendlerpreise nicht verfuegbar.' end
  for _,message in ipairs(problems) do
    if not dependencyWarnings[message] then
      dependencyWarnings[message]=true
      print('|cffff6666FCP: '..message..'|r')
    end
  end
  return problems
end
local function log(s) print('|cff44ccffFCP:|r '..tostring(s)) end
local function money(v)
  if not v then return '?' end
  v = math.floor(v + .5)
  return string.format('|cffffd700%dg|r |cffc0c0c0%ds|r |cffb87333%dc|r', math.floor(v/10000), math.floor(v/100)%100, v%100)
end
local function realmKey()
  local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or 'unknown'
  return realm
end
local function playerKey()
  return (UnitName('player') or '?')..'-'..((GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or '?')
end
local function idFromLink(link)
  if type(link) ~= 'string' then return nil end
  return tonumber(link:match('item:(%d+)'))
end
local function init()
  ForeverCraftProfitDB = ForeverCraftProfitDB or {}
  DB = ForeverCraftProfitDB
  DB.characters = DB.characters or {}
  DB.trainerSkills = DB.trainerSkills or {}
  DB.ignored = DB.ignored or {}
  DB.ui = DB.ui or {sort='profit',desc=true,filter='Alle',search='',showIgnored=false}
  DB.settings = DB.settings or {fee=.05, fallbackVendor=true}
  if DB.ui.profFilter == nil then DB.ui.profFilter='Alle' end
  if DB.ui.charFilter == nil then DB.ui.charFilter='Alle' end
  if DB.ui.onlyProfit == nil then DB.ui.onlyProfit=false end
  DB.ui.columnFilters=DB.ui.columnFilters or {}
  DB.ui.columnFilters.required=nil
  if DB.ui.sort=='required' then DB.ui.sort='profit';DB.ui.desc=true end
  if DB.settings.ahNeutral == nil then DB.settings.ahNeutral=false end
  if DB.settings.duration == nil then DB.settings.duration=8 end
  if DB.settings.autoScan == nil then DB.settings.autoScan=true end
  if DB.settings.showUnlearned == nil then DB.settings.showUnlearned=true end
  if DB.settings.showUnlearnable == nil then DB.settings.showUnlearnable=true end
  -- Einmaliger Neustart der alten Rezeptdatenbank, ohne Fremd-Addon-Daten zu beruehren.
  if (tonumber(DB.version) or 1) < 4 then DB.characters = {} end
  DB.version = 4
end
local function getVendor(id)
  if not DB then init() end
  local scanner = _G.PriceScannerDB
  local record = scanner and scanner.vendor and scanner.vendor[id]
  local scannerPrice = record and tonumber(record.p) or nil
  if scannerPrice and scannerPrice > 0 then return scannerPrice end
  return nil
end
local function auctionPrice(id)
  if not DB then init() end
  if priceCache[id] ~= nil then return priceCache[id] or nil end
  local a = _G.Auctionator
  local api = a and a.API and a.API.v1
  local p
  if api and type(api.GetAuctionPriceByItemID)=='function' then
    local ok, val = pcall(api.GetAuctionPriceByItemID, 'ForeverCraftProfit', id)
    if ok and type(val)=='number' and val>0 then p=val end
  end
  if not p and a and a.Database and type(a.Database.GetPrice)=='function' then
    local ok,val=pcall(a.Database.GetPrice,a.Database,tostring(id))
    if ok and type(val)=='number' and val>0 then p=val end
  end
  priceCache[id] = p or false
  return p
end
local function cheapest(id)
  local ah = auctionPrice(id)
  local vendor = getVendor(id)
  if vendor and vendor>0 and (not ah or vendor<=ah) then return vendor, 'H' end
  if ah then return ah, 'AH' end
  return nil, '?'
end
local function getItemName(id)
  if C_Item and C_Item.GetItemNameByID then
    local ok, n = pcall(C_Item.GetItemNameByID,id)
    if ok and n then return n end
  end
  if GetItemInfo then return GetItemInfo(id) end
  return nil
end
local function scanTrainer()
  if not DB then init() end
  if type(GetNumTrainerServices)~='function' or type(GetTrainerServiceSkillReq)~='function' then return end
  local ok,n=pcall(GetNumTrainerServices)
  if not ok or type(n)~='number' or n<1 then return end
  local realm=realmKey()
  DB.trainerSkills[realm]=DB.trainerSkills[realm] or {}
  local count=0
  for i=1,n do
    local okL,link=pcall(GetTrainerServiceItemLink,i)
    local okS,profession,required=pcall(GetTrainerServiceSkillReq,i)
    local id=okL and idFromLink(link)
    if okS and id and type(required)=='number' and required>0 then
      local prof=(profession=='Alchimie' and 'Alchemie') or profession
      if type(prof)=='string' then
        DB.trainerSkills[realm][prof]=DB.trainerSkills[realm][prof] or {}
        DB.trainerSkills[realm][prof][id]=required
        count=count+1
      end
    end
  end
  if count>0 then resultsDirty=true;cachedResults=nil;if UI and UI:IsShown() then UI.refresh() end end
end
local function requiredSkill(prof,rec)
  local t=DB.trainerSkills and DB.trainerSkills[realmKey()]
  return t and t[prof] and rec.outputID and t[prof][rec.outputID] or nil
end
local function scanProfession()
  if not DB then init() end
  local modern = C_TradeSkillUI and type(C_TradeSkillUI.GetAllRecipeIDs)=='function' and type(C_TradeSkillUI.GetRecipeInfo)=='function' and type(C_TradeSkillUI.GetRecipeSchematic)=='function'
  local classic = type(GetNumTradeSkills)=='function' and type(GetTradeSkillInfo)=='function'
  local name, skill, cap, lineID
  if modern then
    if type(C_TradeSkillUI.GetTradeSkillLine)=='function' then
      local ok,n,sk,mx,lid=pcall(C_TradeSkillUI.GetTradeSkillLine)
      if ok and type(n)=='string' and n~='' then name,skill,cap,lineID=n,sk,mx,lid end
    end
    if type(C_TradeSkillUI.GetTradeSkillLineID)=='function' then
      local ok,lid=pcall(C_TradeSkillUI.GetTradeSkillLineID)
      if ok and type(lid)=='number' and lid>0 then lineID=lid end
    end
    if type(C_TradeSkillUI.GetBaseProfessionInfo)=='function' then
      local ok,info=pcall(C_TradeSkillUI.GetBaseProfessionInfo)
      if ok and type(info)=='table' then
        name=name or info.professionName or info.name
        lineID=lineID or info.professionID or info.skillLineID
      end
    end
  end
  if not name and classic and type(GetTradeSkillLine)=='function' then
    local ok,n,sk,mx=pcall(GetTradeSkillLine)
    if ok and type(n)=='string' and n~='' and n~='UNKNOWN' then name,skill,cap=n,sk,mx end
  end
  -- Some Forever builds expose the modern recipe APIs but no profession-line API.
  -- A name passed via /fcp scan Alchemie is always accepted as an override.
  if not modern and not classic then
    log('Keine Rezept-API gefunden. Modern='..tostring(modern)..', Classic='..tostring(classic))
    return
  end
  if type(FCPScanName)=='string' and FCPScanName~='' then name=FCPScanName end
  if name=='Alchimie' then name='Alchemie' end
  if not name then
    if type(FCPScanName)=='string' and FCPScanName~='' then name=FCPScanName end
    if not name and type(GetProfessions)=='function' and type(GetProfessionInfo)=='function' then
      local ids={GetProfessions()}
      local matches={}
      for _,id in ipairs(ids) do
        if id then
          local ok,n=pcall(GetProfessionInfo,id)
          if ok and n then matches[#matches+1]=n end
        end
      end
      if #matches==1 then name=matches[1] end
    end
    name=name or ('Unbekannter Beruf '..tostring(lineID or ''))
  end
  local chKey=playerKey()
  local ch=DB.characters[chKey] or {professions={}}
  DB.characters[chKey]=ch
  ch.faction=UnitFactionGroup('player')
  ch.realm=(GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
  local key=tostring(lineID or name)
  local prof=ch.professions[key] or {recipes={}}
  ch.professions[key]=prof
  prof.name,prof.skill,prof.cap,prof.scannedAt=name,skill or 0,cap or 0,time()
  local count=0
  local scannedProfessions={}
  local countsByProfession={}
  if modern and type(C_TradeSkillUI.GetAllRecipeIDs)=='function' then
    local okIDs,ids=pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if okIDs and type(ids)=='table' then
      for _,recipeID in ipairs(ids) do
        local ok,info=pcall(C_TradeSkillUI.GetRecipeInfo,recipeID)
        if ok and info and (info.learned or DB.settings.showUnlearned) then
          -- Recipe-specific profession metadata is reliable even for unlearned recipes.
          local rp
          if type(C_TradeSkillUI.GetProfessionInfoByRecipeID)=='function' then
            local okP,pinfo=pcall(C_TradeSkillUI.GetProfessionInfoByRecipeID,recipeID)
            if okP and type(pinfo)=='table' then rp=pinfo end
          end
          local recipeLine=rp and (rp.professionID or rp.parentProfessionID)
          local recipeName=rp and (rp.parentProfessionName or rp.professionName)
          local target=prof
          if rp and recipeLine then
            local professionKey=tostring(recipeLine)
            target=ch.professions[professionKey]
            if not target then target={recipes={}};ch.professions[professionKey]=target end
            target.recipes=target.recipes or {}
            target.name=(recipeName=='Alchimie' and 'Alchemie') or recipeName or name
            target.skill=rp.skillLevel or 0
            target.cap=rp.maxSkillLevel or 0
            target.scannedAt=time()
            scannedProfessions[professionKey]=true
            countsByProfession[professionKey]=(countsByProfession[professionKey] or 0)+1
          elseif not info.learned then
            -- Unknown recipes must not be assigned to a guessed profession.
            target=nil
          end
          if target then
          local okS,schematic=pcall(C_TradeSkillUI.GetRecipeSchematic,recipeID,false)
          if okS and schematic then
            local reagents={}
            local missing=false
            for _,slot in ipairs(schematic.reagentSlotSchematics or {}) do
              local qty=slot.quantityRequired or 0
              local options={}
              for _,reagent in ipairs(slot.reagents or {}) do
                local id=reagent.itemID or (reagent.item and reagent.item.itemID)
                if id then options[#options+1]=id end
              end
              if qty>0 then
                if #options==0 then missing=true end
                reagents[#reagents+1]={qty=qty,options=options}
              end
            end
            local outputID=schematic.outputItemID
            if not outputID and C_TradeSkillUI.GetRecipeItemLink then
              local okL,link=pcall(C_TradeSkillUI.GetRecipeItemLink,recipeID)
              if okL then outputID=idFromLink(link) end
            end
            target.recipes[tostring(recipeID)]={id=recipeID,icon=info.icon,name=info.name or tostring(recipeID),outputID=outputID,outputQty=schematic.quantityMin or 1,reagents=reagents,incomplete=missing,isEnchant=info.isEnchantingRecipe or false,learned=info.learned and true or false,unlearnable=info.unlearnable or info.isUnlearnable or false,relativeDifficulty=info.relativeDifficulty,canSkillUp=info.canSkillUp,numSkillUps=info.numSkillUps}
            count=count+1
          end
          end
        end
      end
    end
  end
  -- Drop the empty fallback group when every recipe was attributed precisely.
  if modern and next(scannedProfessions) and not next(prof.recipes or {}) and not scannedProfessions[key] then
    ch.professions[key]=nil
  end
  -- Classic/Forever profession interface: recipe indices, not retail recipe IDs.
  if count==0 and classic then
    local okN,n=pcall(GetNumTradeSkills)
    if okN and type(n)=='number' then
      for i=1,n do
        local okInfo,recipeName,kind=pcall(GetTradeSkillInfo,i)
        if okInfo and recipeName and kind~='header' then
          local outputLink
          if type(GetTradeSkillItemLink)=='function' then
            local okL,link=pcall(GetTradeSkillItemLink,i)
            if okL then outputLink=link end
          end
          local outputID=idFromLink(outputLink)
          local qty=1
          if type(GetTradeSkillNumMade)=='function' then
            local okQ,minQ=pcall(GetTradeSkillNumMade,i)
            if okQ and type(minQ)=='number' and minQ>0 then qty=minQ end
          end
          local reagents={}
          local incomplete=false
          local nr=0
          if type(GetTradeSkillNumReagents)=='function' then
            local okR,r=pcall(GetTradeSkillNumReagents,i)
            if okR and type(r)=='number' then nr=r end
          end
          for j=1,nr do
            local amount=0
            if type(GetTradeSkillReagentInfo)=='function' then
              local okR,_,_,required=pcall(GetTradeSkillReagentInfo,i,j)
              if okR then amount=required or 0 end
            end
            local reagentID
            if type(GetTradeSkillReagentItemLink)=='function' then
              local okL,link=pcall(GetTradeSkillReagentItemLink,i,j)
              if okL then reagentID=idFromLink(link) end
            end
            if not reagentID then incomplete=true end
            reagents[#reagents+1]={qty=amount,options=reagentID and {reagentID} or {}}
          end
          local recipeKey=outputID and ('item:'..outputID) or ('recipe:'..recipeName)
          prof.recipes[recipeKey]={name=recipeName,outputID=outputID,outputQty=qty,reagents=reagents,incomplete=incomplete,isEnchant=not outputID}
          count=count+1
        end
      end
    end
  end
  if count>0 then
    local summary={}
    for k,n in pairs(countsByProfession) do
      local group=ch.professions[k]
      summary[#summary+1]=(group and group.name or k)..': '..n
    end
    table.sort(summary)
    local signature=table.concat(summary,', ')
    if signature=='' then signature=name..': '..count end
    if F.manualScan then log('Scan: '..signature..' Rezepte');F.manualScan=false end
  end
  if count==0 and F.manualScan then log('Keine Rezepte erfasst. Berufsfenster prüfen.');F.manualScan=false end
  if count>0 then invalidateRecipes() end
  if UI and UI:IsShown() then UI.refresh() end
end
-- Index der auf dieser Spielwelt erfassten, gelernten Herstellungsrezepte.
-- Ein Zwischenprodukt wird nur selbst hergestellt, wenn die Rezeptdaten vollstaendig sind.
local craftingIndex={}
local function rebuildCraftingIndex()
  if not craftingIndexDirty then return end
  craftingIndexDirty=false
  craftingIndex={}
  local realm=realmKey()
  for char,ch in pairs(DB.characters or {}) do
    if (ch.realm or char:match('%-(.+)$') or '')==realm then
      for _,prof in pairs(ch.professions or {}) do
        for _,rec in pairs(prof.recipes or {}) do
          if rec.outputID and rec.learned==true and not rec.incomplete and rec.reagents and #rec.reagents>0 then
            local id=tonumber(rec.outputID)
            if id then
              craftingIndex[id]=craftingIndex[id] or {}
              craftingIndex[id][#craftingIndex[id]+1]=rec
            end
          end
        end
      end
    end
  end
end
-- Vergleicht AH/Händler mit rekursiver Eigenherstellung, inklusive Ausbeute.
local function materialPrice(id,active,depth)
  id=tonumber(id)
  if not id then return nil,nil end
  local best,source=cheapest(id)
  if depth>=12 or active[id] then return best,source end
  active[id]=true
  for _,rec in ipairs(craftingIndex[id] or {}) do
    local total,valid=0,true
    for _,slot in ipairs(rec.reagents or {}) do
      local cheapestSlot
      for _,reagentID in ipairs(slot.options or {}) do
        local unit=materialPrice(reagentID,active,depth+1)
        if unit and (not cheapestSlot or unit<cheapestSlot) then cheapestSlot=unit end
      end
      if not cheapestSlot then valid=false;break end
      total=total+cheapestSlot*(tonumber(slot.qty) or 1)
    end
    if valid then
      local outputQty=math.max(1,tonumber(rec.outputQty) or 1)
      local unit=total/outputQty
      if not best or unit<best then best,source=unit,'Herstellung' end
    end
  end
  active[id]=nil
  return best,source
end
local function evaluate(rec)
  if not rec.outputID then return nil,nil,'Kein verkaufbarer Gegenstand' end
  if rec.incomplete then return nil,nil,'Reagenzien nicht auflösbar' end
  local total=0
  local missing={}
  local active={[tonumber(rec.outputID) or 0]=true}
  for _,slot in ipairs(rec.reagents or {}) do
    local best
    for _,id in ipairs(slot.options or {}) do
      local p=materialPrice(id,active,0)
      if p and (not best or p<best) then best=p end
    end
    if best then total=total+best*(tonumber(slot.qty) or 1) else
      missing[#missing+1] = (#(slot.options or {})>0 and tostring(slot.options[1]) or '?')
    end
  end
  if #missing>0 then return nil,nil,'Preise fehlen: '..table.concat(missing, ', ') end
  local sale=auctionPrice(rec.outputID)
  if not sale then return nil,total,'Kein AH-Preis für Produkt' end
  local gross=sale*(rec.outputQty or 1)
  local profit=gross*(DB.settings.ahNeutral and .85 or .95)-total
  return profit,total,nil,gross
end
local function recipeKey(rec)
  return rec.outputID and ('item:'..tostring(rec.outputID)) or ('recipe:'..tostring(rec.id or rec.name))
end
local function results()
  if not resultsDirty and cachedResults then return cachedResults end
  rebuildCraftingIndex()
  local out, selected={},{}
  local cfg=DB.ui
  local search=(cfg.search or ''):lower()
  local realm=realmKey()
  for char,ch in pairs(DB.characters) do
    if (ch.realm or char:match('%-(.+)$') or '')==realm then
      for profKey,prof in pairs(ch.professions or {}) do
        for recKey,rec in pairs(prof.recipes or {}) do
          local key=recipeKey(rec)
          local ignored=DB.ignored[key] and true or false
          local unique=char..':'..key
          if (cfg.filter=='Alle' or cfg.filter==prof.name) and cfg.showIgnored==ignored
            and (cfg.showIgnored or rec.learned~=false or DB.settings.showUnlearned)
            and (cfg.showIgnored or not rec.unlearnable or DB.settings.showUnlearnable)
            and ((rec.name or ''):lower():find(search,1,true) or (prof.name or ''):lower():find(search,1,true)) then
            local candidate={char=char,prof=prof.name or '?',profKey=profKey,recKey=recKey,rec=rec,key=key}
            local previous=selected[unique]
            local function quality(e)
              local q=0
              if e.prof~='?' and not e.prof:find('Unbekannter Beruf',1,true) then q=q+100 end
              if e.rec.id then q=q+10 end
              if e.rec.outputID then q=q+5 end
              if e.rec.reagents and #e.rec.reagents>0 then q=q+1 end
              return q
            end
            if not previous or quality(candidate)>quality(previous) then selected[unique]=candidate end
          end
        end
      end
    end
  end
  for _,e in pairs(selected) do
    e.profit,e.cost,e.reason,e.gross=evaluate(e.rec)
    e.requiredSkill=requiredSkill(e.prof,e.rec)
    local ch=DB.characters[e.char]
    local p=ch and ch.professions[e.profKey]
    e.skillTooLow=e.rec.learned==false and e.requiredSkill and p and type(p.skill)=='number' and p.skill>0 and p.skill<e.requiredSkill or false
    local cf=cfg.columnFilters or {}
    local function passes(k,v)
      local chosen=cf[k]
      if not chosen or not next(chosen) then return true end
      return chosen[tostring(v)]==true
    end
    local function priceBand(v)
      if not v then return 'Unbekannt' end
      if v<0 then return 'Negativ' end
      if v==0 then return 'Null' end
      if v<10000 then return 'Unter 1 Gold' end
      if v<100000 then return '1 bis 10 Gold' end
      if v<1000000 then return '10 bis 100 Gold' end
      return 'Ab 100 Gold'
    end
    if (cfg.showIgnored or not cfg.onlyProfit or (e.profit and e.profit>0)) and (cfg.charFilter=='Alle' or cfg.charFilter==e.char) and (cfg.profFilter=='Alle' or cfg.profFilter==e.prof)
      and (cfg.showIgnored or (passes('prof',e.prof) and passes('char',e.char)
      and passes('name',e.rec.learned==false and 'Nicht gelernt' or 'Gelernt')
      and passes('cost',priceBand(e.cost)) and passes('profit',priceBand(e.profit)) and passes('gross',priceBand(e.gross)))) then out[#out+1]=e end
  end
  local function value(e,k)
    if k=='skill' then return e.rec.relativeDifficulty or -1 end
    if k=='name' then return (e.rec.name or ''):lower() end
    if k=='prof' then return (e.prof or ''):lower() end
    if k=='char' then return (e.char or ''):lower() end
    if k=='gross' then return e.gross end
    if k=='cost' then return e.cost end
    return e.profit
  end
  table.sort(out,function(a,b)
    local va,vb=value(a,cfg.sort),value(b,cfg.sort)
    if va==nil and vb~=nil then return false end
    if vb==nil and va~=nil then return true end
    if va~=vb then
      if va==nil then return false end
      if vb==nil then return true end
      if cfg.desc then return va>vb else return va<vb end
    end
    return (a.rec.name or '')<(b.rec.name or '')
  end)
  cachedResults=out
  resultsDirty=false
  return out
end
local function openRecipe(e)
  if e.char~=playerKey() then log('Rezept gehoert zu einem anderen Charakter. Auf diesen Charakter wechseln.');return end
  local recipeID=tonumber(e.rec.id)
  if not recipeID then log('Fuer dieses Rezept ist keine Rezept-ID gespeichert.');return end
  -- Profession UI is custom on Forever. Try supported entry points without assuming they exist.
  if C_TradeSkillUI and type(C_TradeSkillUI.OpenTradeSkill)=='function' then
    pcall(C_TradeSkillUI.OpenTradeSkill, tonumber(e.profKey))
  end
  if type(ProfessionsFrame_LoadUI)=='function' then pcall(ProfessionsFrame_LoadUI) end
  -- Never call a toggle here: it would close an already-open profession window.
  if not (_G.ProfessionsFrame and _G.ProfessionsFrame.IsShown and _G.ProfessionsFrame:IsShown()) then
    if type(ShowUIPanel)=='function' and _G.ProfessionsFrame then pcall(ShowUIPanel,_G.ProfessionsFrame) end
  end
  local page=_G.ProfessionsFrame and _G.ProfessionsFrame.CraftingPage
  local list=page and page.RecipeList
  if list and type(list.SelectRecipe)=='function' and C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
    local ok,info=pcall(C_TradeSkillUI.GetRecipeInfo,recipeID)
    if ok and type(info)=='table' then
      local selected,err=pcall(list.SelectRecipe,list,info)
      if selected then
        local form=page.SchematicForm
        local actual=form and type(form.GetRecipeInfo)=='function' and form:GetRecipeInfo()
        if actual and actual.recipeID==recipeID then return end
        log('Rezept '..recipeID..' ist in der aktiven Berufsliste nicht auswaehlbar.')
        return
      end
      log('Rezeptauswahl fehlgeschlagen: '..tostring(err));return
    end
  end
  log('Rezeptliste noch nicht bereit. Beruf zuerst auswaehlen.')
end
local materialWindow
local function showMaterials(entry)
  if not DB then init() end
  if not materialWindow then
    local p=CreateFrame('Frame','FCPMaterialWindow',UIParent,'BasicFrameTemplateWithInset')
    p:SetFrameStrata('FULLSCREEN_DIALOG');p:SetFrameLevel(210)
    p:SetSize(545,390);p:SetPoint('CENTER',UIParent,'CENTER',-130,20)
    p:SetMovable(true);p:EnableMouse(true);p:RegisterForDrag('LeftButton')
    p:SetScript('OnDragStart',function(self) self:StartMoving() end)
    p:SetScript('OnDragStop',function(self) self:StopMovingOrSizing() end)
    p:SetClampedToScreen(true)
    if p.Bg then p.Bg:SetAlpha(0) end
    if p.Inset and p.Inset.Bg then p.Inset.Bg:SetAlpha(0) end
    if p.TitleBg then p.TitleBg:SetVertexColor(.18,.13,.09,1) end
    local bg=p:CreateTexture(nil,'BACKGROUND')
    bg:SetPoint('TOPLEFT',p,'TOPLEFT',7,-22);bg:SetPoint('BOTTOMRIGHT',p,'BOTTOMRIGHT',-7,7)
    bg:SetTexture('Interface\\QuestFrame\\QuestBG')
    bg:SetTexCoord(0,1,0,1)
    bg:SetVertexColor(.86,.76,.58,1)
    local back=CreateFrame('Button',nil,p,'UIPanelButtonTemplate')
    back:SetSize(28,22);back:SetPoint('TOPLEFT',p,'TOPLEFT',10,-27);back:SetText('<')
    back:SetScript('OnClick',function() p:Hide();if UI then UI:Show();UI.refresh() end end)
    local amountLabel=p:CreateFontString(nil,'OVERLAY','GameFontNormal')
    amountLabel:SetPoint('TOPLEFT',p,'TOPLEFT',20,-39);amountLabel:SetText('Herstellungen:')
    local quantity=CreateFrame('EditBox',nil,p,'InputBoxTemplate')
    quantity:SetSize(65,24);quantity:SetPoint('LEFT',amountLabel,'RIGHT',15,0)
    quantity:SetAutoFocus(false);quantity:SetNumeric(true);quantity:SetText('1')
    quantity:SetScript('OnEscapePressed',function(self) self:ClearFocus() end)
    p.quantity=quantity
    local headings=p:CreateFontString(nil,'OVERLAY','GameFontNormalSmall')
    headings:SetPoint('TOPLEFT',p,'TOPLEFT',22,-72)
    headings:SetText('Material                                      Menge      Einzelpreis      Gesamt      Quelle')
    p.items={}
    for i=1,9 do
      local b=CreateFrame('Button',nil,p)
      b:SetSize(500,27);b:SetPoint('TOPLEFT',p,'TOPLEFT',20,-91-(i-1)*28)
      local tex=b:CreateTexture(nil,'ARTWORK');tex:SetSize(24,24);tex:SetPoint('LEFT',b,'LEFT',0,0)
      local name=b:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall');name:SetPoint('LEFT',tex,'RIGHT',5,0);name:SetWidth(145);name:SetJustifyH('LEFT')
      local qty=b:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall');qty:SetPoint('LEFT',b,'LEFT',177,0);qty:SetWidth(48);qty:SetJustifyH('RIGHT')
      local unit=b:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall');unit:SetPoint('LEFT',b,'LEFT',230,0);unit:SetWidth(85);unit:SetJustifyH('RIGHT')
      local cost=b:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall');cost:SetPoint('LEFT',b,'LEFT',320,0);cost:SetWidth(105);cost:SetJustifyH('RIGHT')
      local src=b:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall');src:SetPoint('LEFT',b,'LEFT',435,0);src:SetWidth(40);src:SetJustifyH('CENTER')
      b:SetScript('OnEnter',function(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
        if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemID)
        elseif GameTooltip.SetHyperlink then GameTooltip:SetHyperlink('item:'..self.itemID) end
        GameTooltip:Show()
      end)
      b:SetScript('OnLeave',function() GameTooltip:Hide() end)
      p.items[i]={button=b,icon=tex,name=name,qty=qty,unit=unit,cost=cost,src=src}
    end
    local summary=p:CreateFontString(nil,'OVERLAY','GameFontHighlight')
    summary:SetPoint('BOTTOMLEFT',p,'BOTTOMLEFT',22,19);summary:SetWidth(490);summary:SetJustifyH('LEFT')
    p.summary=summary
    local prev=CreateFrame('Button',nil,p,'UIPanelButtonTemplate')
    prev:SetSize(24,23);prev:SetPoint('BOTTOMRIGHT',p,'BOTTOMRIGHT',-49,58);prev:SetText('<')
    local next=CreateFrame('Button',nil,p,'UIPanelButtonTemplate')
    next:SetSize(24,23);next:SetPoint('LEFT',prev,'RIGHT',3,0);next:SetText('>')
    local pageLabel=p:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
    pageLabel:SetPoint('RIGHT',prev,'LEFT',-8,0);p.pageLabel=pageLabel
    local function update()
      local e=p.entry
      if not e then return end
      local n=math.max(1,math.min(99999,tonumber(quantity:GetText()) or 1))
      local slots={}
      local function addSlot(slot,depth,active)
        local bestID,bestPrice,bestSource
        for _,id in ipairs(slot.options or {}) do
          local price,source=materialPrice(id,active,0)
          if price and (not bestPrice or price<bestPrice) then bestID,bestPrice,bestSource=id,price,source end
        end
        if bestID and bestSource=='Herstellung' and depth<8 and not active[bestID] then
          local chosen,bestUnit
          for _,recipe in ipairs(craftingIndex[bestID] or {}) do
            local total,valid=0,true
            for _,sub in ipairs(recipe.reagents or {}) do
              local subBest
              for _,subID in ipairs(sub.options or {}) do
                local price=materialPrice(subID,{[bestID]=true},0)
                if price and (not subBest or price<subBest) then subBest=price end
              end
              if not subBest then valid=false;break end
              total=total+subBest*(tonumber(sub.qty) or 1)
            end
            if valid then
              local unit=total/math.max(1,tonumber(recipe.outputQty) or 1)
              if not bestUnit or unit<bestUnit then chosen,bestUnit=recipe,unit end
            end
          end
          if chosen then
            active[bestID]=true
            local factor=(tonumber(slot.qty) or 1)/math.max(1,tonumber(chosen.outputQty) or 1)
            for _,sub in ipairs(chosen.reagents or {}) do
              addSlot({qty=(tonumber(sub.qty) or 1)*factor,options=sub.options},depth+1,active)
            end
            active[bestID]=nil
            return
          end
        end
        slots[#slots+1]=slot
      end
      for _,slot in ipairs(e.rec.reagents or {}) do addSlot(slot,0,{[tonumber(e.rec.outputID) or 0]=true}) end
      local maxPage=math.max(1,math.ceil(#slots/9))
      p.page=math.max(1,math.min(p.page or 1,maxPage))
      pageLabel:SetText(p.page..' / '..maxPage)
      for i,row in ipairs(p.items) do
        local slot=slots[(p.page-1)*9+i]
        if slot then
          local bestID,bestPrice,bestSource
          for _,id in ipairs(slot.options or {}) do
            local price,source=materialPrice(id,{[tonumber(e.rec.outputID) or 0]=true},0)
            if not bestID or (price and (not bestPrice or price<bestPrice)) then bestID,bestPrice,bestSource=id,price,source end
          end
          row.button.itemID=bestID
          local icon
          if bestID and C_Item and C_Item.GetItemIconByID then
            local ok,val=pcall(C_Item.GetItemIconByID,bestID);if ok then icon=val end
          end
          if not icon and bestID and GetItemIcon then icon=GetItemIcon(bestID) end
          row.icon:SetTexture(icon or 'Interface\\Icons\\INV_Misc_QuestionMark')
          row.name:SetText(bestID and (getItemName(bestID) or ('Item '..bestID)) or 'Unbekannt')
          row.qty:SetText(tostring((slot.qty or 0)*n))
          row.unit:SetText(money(bestPrice))
          row.cost:SetText(money(bestPrice and bestPrice*(slot.qty or 0)*n))
          row.src:SetText(bestSource or '?')
          row.button:Show()
        else row.button:Hide() end
      end
      local profit,cost,reason,gross=evaluate(e.rec)
      summary:SetText('Material: '..money(cost and cost*n)..'   Erlös: '..money(gross and gross*n)..'   Gewinn: '..money(profit and profit*n)..(reason and ('  ('..reason..')') or ''))
    end
    p.update=update
    quantity:SetScript('OnTextChanged',function() if p.entry then update() end end)
    prev:SetScript('OnClick',function() p.page=(p.page or 1)-1;update() end)
    next:SetScript('OnClick',function() p.page=(p.page or 1)+1;update() end)
    materialWindow=p
  end
  materialWindow.entry=entry;materialWindow.page=1
  materialWindow.TitleText:SetText('Materialien: '..(entry.rec.name or '?'))
  materialWindow.update();if UI then UI:Hide() end;materialWindow:Show()
end
local function makeDropdown(anchor, optionsFn, onSelect)
  local popup=CreateFrame('Frame',nil,UIParent,'BackdropTemplate')
  popup:SetFrameStrata('FULLSCREEN_DIALOG')
  popup:SetFrameLevel(200)
  popup:SetBackdrop({bgFile='Interface\\Tooltips\\UI-Tooltip-Background',edgeFile='Interface\\Tooltips\\UI-Tooltip-Border',tile=true,tileSize=16,edgeSize=12,insets={left=3,right=3,top=3,bottom=3}})
  popup:SetBackdropColor(0.06,0.06,0.08,0.98)
  popup:Hide()
  local blocker=CreateFrame('Button',nil,UIParent)
  blocker:SetAllPoints(UIParent)
  blocker:SetFrameStrata('FULLSCREEN_DIALOG')
  blocker:SetFrameLevel(199)
  blocker:EnableMouse(true)
  blocker:Hide()
  blocker:SetScript('OnClick',function() popup:Hide() end)
  blocker:RegisterForClicks('AnyUp')
  popup:SetScript('OnHide',function() blocker:Hide() end)
  local entries={}
  local function openMenu(force)
    if popup:IsShown() and not force then popup:Hide();return end
    local options=optionsFn()
    popup:SetSize(math.max(anchor:GetWidth(),185),math.max(1,#options)*23+10)
    popup:ClearAllPoints()
    popup:SetPoint('TOPLEFT',anchor,'BOTTOMLEFT',0,-2)
    for i,option in ipairs(options) do
      local b=entries[i]
      if not b then
        b=CreateFrame('Button',nil,popup)
        b:SetHeight(23)
        b.label=b:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
        b.label:SetPoint('LEFT',b,'LEFT',9,0)
        b.label:SetJustifyH('LEFT')
        local hi=b:CreateTexture(nil,'HIGHLIGHT');hi:SetAllPoints();hi:SetColorTexture(1,1,1,0.15)
        entries[i]=b
      end
      b:ClearAllPoints();b:SetPoint('TOPLEFT',popup,'TOPLEFT',5,-5-(i-1)*23)
      b:SetPoint('RIGHT',popup,'RIGHT',-5,0)
      b.label:SetText(option.label or tostring(option.value))
      b:SetScript('OnClick',function() popup.navigating=true;popup:Hide();local keep=onSelect(option.value);if keep then openMenu(true) end;popup.navigating=false end)
      b:Show()
    end
    for i=#options+1,#entries do entries[i]:Hide() end
    blocker:Show()
    popup:Show()
  end
  popup.openMenu=openMenu
  anchor:SetScript('OnClick',function() if anchor.fcpBeforeOpen and not popup:IsShown() then anchor.fcpBeforeOpen() end;openMenu() end)
  anchor:HookScript('OnHide',function() popup:Hide() end)
  return popup
end
local function createUI()
  local w=CreateFrame('Frame','ForeverCraftProfitWindow',UIParent,'BasicFrameTemplateWithInset')
  w:SetSize(DB.ui.width or 970,DB.ui.height or 535)
  w:SetFrameStrata('DIALOG');w:SetFrameLevel(120)
  w:SetResizable(true);w:SetResizeBounds(970,340,1500,950)
  local bg=w:CreateTexture(nil,'BACKGROUND')
  bg:SetPoint('TOPLEFT',w,'TOPLEFT',7,-22);bg:SetPoint('BOTTOMRIGHT',w,'BOTTOMRIGHT',-7,7)
  bg:SetColorTexture(27/255,22/255,17/255,1)
  w:SetPoint('CENTER',UIParent,'CENTER',160,0)
  w:SetMovable(true);w:EnableMouse(true);w:RegisterForDrag('LeftButton')
  w:SetScript('OnDragStart',function(self) self:StartMoving() end)
  w:SetScript('OnDragStop',function(self)
    self:StopMovingOrSizing()
    local x,y=self:GetCenter()
    if x and y then DB.ui.x=x;DB.ui.y=y end
  end)
  if DB.ui.x and DB.ui.y then w:ClearAllPoints();w:SetPoint('CENTER',UIParent,'BOTTOMLEFT',DB.ui.x,DB.ui.y) end
  w:SetClampedToScreen(true)
  if w.Bg then w.Bg:SetAlpha(0) end
  if w.Inset and w.Inset.Bg then w.Inset.Bg:SetAlpha(0) end
  if w.TitleBg then w.TitleBg:SetVertexColor(.18,.13,.09,1) end
  if w.TopTileStreaks then w.TopTileStreaks:SetVertexColor(.18,.13,.09,1) end
  w.TitleText:SetText('Forever Craft Profit v'..VERSION)
  w:Hide()
  local hint=w:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
  hint:SetPoint('TOPLEFT',w,'TOPLEFT',17,-35)
  hint:SetText('')
  local help=CreateFrame('Button',nil,w,'UIPanelButtonTemplate')
  help:SetSize(24,22);help:SetText('?');help:SetPoint('TOPRIGHT',w,'TOPRIGHT',-43,-27)
  help:SetScript('OnEnter',function(self)
    GameTooltip:SetOwner(self,'ANCHOR_BOTTOMLEFT')
    GameTooltip:AddLine('Bedienung',1,.82,.2)
    GameTooltip:AddLine('Klick: Materialien anzeigen',1,1,1)
    GameTooltip:AddLine('Shift + Klick: Beruf und Rezept oeffnen',1,1,1)
    GameTooltip:AddLine('Strg + Klick: Rezept ignorieren',1,1,1)
    GameTooltip:AddLine('Fraktions-AH: 5 % Provision; neutrales AH: 15 %.',1,1,1)
    GameTooltip:AddLine('Provision nur bei erfolgreichem Verkauf.',1,1,1)
    GameTooltip:AddLine('Kaution wird bei erfolgreichem Verkauf erstattet.',1,1,1)
    GameTooltip:Show()
  end)
  help:SetScript('OnLeave',function() GameTooltip:Hide() end)
  local freshness=CreateFrame('Frame',nil,w)
  freshness:SetSize(330,23);freshness:SetPoint('BOTTOMRIGHT',w,'BOTTOMRIGHT',-19,8)
  local indicators={}
  local function addIndicator(label,index)
    local b=CreateFrame('Frame',nil,freshness)
    b:SetSize(158,22);b:SetPoint('LEFT',freshness,'LEFT',(index-1)*164,0)
    b:EnableMouse(true)
    local t=b:CreateFontString(nil,'OVERLAY','GameFontNormalSmall')
    t:SetAllPoints();t:SetJustifyH('CENTER');b.label=t
    b:SetScript('OnEnter',function(self)
      GameTooltip:SetOwner(self,'ANCHOR_TOP')
      GameTooltip:AddLine(self.tipTitle or label,1,.82,.25)
      GameTooltip:AddLine(self.tip or 'Aktualisierungszeit unbekannt',1,1,1,true)
      GameTooltip:Show()
    end)
    b:SetScript('OnLeave',function() GameTooltip:Hide() end)
    indicators[index]=b
  end
  addIndicator('Auctionator',1)
  addIndicator('Price Scanner',2)
  local function updateFreshness()
    local b=indicators[1]
    local a=_G.Auctionator
    local database=a and a.Database
    if database and type(database.GetPriceAge)=='function' then
      b.label:SetText('|cff55dd88AH: Verbunden|r')
      b.tipTitle='Auctionator: Preisalter'
      b.tip='Das Preisalter ist gegenstandsbezogen. Bei unbekanntem Preis kein Alter vorhanden.'
    else
      b.label:SetText('|cffff6666AH: Nicht verfuegbar|r')
      b.tipTitle='Auctionator'
      b.tip='Preisdatenbank nicht verfuegbar.'
    end
    local v=indicators[2]
    if _G.PriceScannerDB and type(_G.PriceScannerDB.vendor)=='table' then
      v.label:SetText('|cff55dd88Scanner: Verbunden|r')
      v.tip='Price Scanner Forever: Haendlerpreisdaten vorhanden. Das bedeutet nicht, dass die Preise aktuell sind.'
    else
      v.label:SetText('|cffff6666Scanner: Fehlt|r')
      v.tip='Keine Price-Scanner-Haendlerpreisdaten verfuegbar.'
    end
  end
  local search=CreateFrame('EditBox',nil,w,'InputBoxTemplate')
  local searchLabel=w:CreateFontString(nil,'OVERLAY','GameFontNormalSmall')
  searchLabel:SetPoint('TOPLEFT',w,'TOPLEFT',22,-45);searchLabel:SetText('Suche:')
  search:SetSize(220,22);search:SetPoint('TOPLEFT',w,'TOPLEFT',22,-68)
  local clearSearch=CreateFrame('Button',nil,w,'UIPanelCloseButton')
  clearSearch:SetSize(19,19);clearSearch:SetPoint('RIGHT',search,'RIGHT',-2,0)
  clearSearch:SetScript('OnClick',function() search:SetText('');search:SetFocus() end)
  local function syncClear() if search:GetText()~='' then clearSearch:Show() else clearSearch:Hide() end end
  search:SetAutoFocus(false);search:SetText(DB.ui.search or '')
  search:SetScript('OnTextChanged',function(self) DB.ui.search=self:GetText();syncClear();if w.refresh then w.refresh() end end)
  syncClear()
  search:SetScript('OnEscapePressed',function(self) self:ClearFocus() end)
  local filter=CreateFrame('Button',nil,w,'UIPanelButtonTemplate')
  filter:SetSize(150,23);filter:SetPoint('LEFT',search,'RIGHT',13,0)
  local ignored=CreateFrame('Button',nil,w,'UIPanelButtonTemplate')
  ignored:SetSize(145,23);ignored:SetPoint('LEFT',filter,'RIGHT',8,0)
  local refresh=CreateFrame('Button',nil,w,'UIPanelButtonTemplate')
  refresh:SetSize(110,23);refresh:SetPoint('TOPRIGHT',w,'TOPRIGHT',-18,-68)
  refresh:SetText('Calc: Refresh')
  local manage=CreateFrame('Button',nil,w,'UIPanelButtonTemplate')
  manage:SetSize(98,23);manage:SetPoint('RIGHT',refresh,'LEFT',-7,0)
  manage:SetText('Datenbank');manage:Hide()
  local dbMenu,databaseOptions,chooseDB
  local options=CreateFrame('Button',nil,w,'UIPanelButtonTemplate')
  options:SetSize(92,22);options:SetPoint('TOPRIGHT',w,'TOPRIGHT',-75,-27)
  options:SetText('Optionen')
  local optionsPopup=makeDropdown(options,function()
    if dbMenu=='duration' then return {{label='< Optionen',value='options'},{label='2 Stunden',value='duration:2'},{label='8 Stunden (Standard)',value='duration:8'},{label='24 Stunden',value='duration:24'}} end
    if dbMenu then return databaseOptions() end
    return {
      {label='Datenbank  >',value='database'},
      {label='AH-Laufzeit: '..tostring(DB.settings.duration or 8)..' h  >',value='duration'},
      {label='Automatischer Scan: '..(DB.settings.autoScan and 'Ein' or 'Aus'),value='autoscan'},
      {label='AH-Typ: '..(DB.settings.ahNeutral and 'Neutral (15 %)' or 'Fraktion (5 %)'),value='ahtype'},
    }
  end,function(v)
    if v=='database' then dbMenu='root';return true end
    if v=='duration' then dbMenu='duration';return true end
    if v=='options' and dbMenu=='duration' then dbMenu=nil;return true end
    if type(v)=='string' and v:sub(1,9)=='duration:' then DB.settings.duration=tonumber(v:sub(10)) or 8;dbMenu=nil;return false end
    if dbMenu then local keep=chooseDB(v);return keep end
    if v=='autoscan' then DB.settings.autoScan=not DB.settings.autoScan
    elseif v=='ahtype' then DB.settings.ahNeutral=not DB.settings.ahNeutral
    end
    if w.refresh then w.refresh() end
  end)
  optionsPopup:HookScript('OnHide',function() if not optionsPopup.navigating then dbMenu=nil end end)
  options.fcpBeforeOpen=function() dbMenu=nil end
  local resize=CreateFrame('Button',nil,w)
  resize:SetSize(22,22);resize:SetPoint('BOTTOMRIGHT',w,'BOTTOMRIGHT',-3,3)
  local grip=resize:CreateTexture(nil,'OVERLAY');grip:SetAllPoints();grip:SetTexture('Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up')
  resize:SetScript('OnMouseDown',function() w:StartSizing('BOTTOMRIGHT') end)
  resize:SetScript('OnMouseUp',function() w:StopMovingOrSizing();DB.ui.width=w:GetWidth();DB.ui.height=w:GetHeight();if w.refresh then w.refresh() end end)
  w:SetScript('OnSizeChanged',function() if w.refresh then w.refresh() end end)
  local scan=CreateFrame('Button',nil,w,'UIPanelButtonTemplate')
  scan:SetSize(115,23);scan:SetPoint('RIGHT',refresh,'LEFT',-7,0)
  scan:SetText('Scan: Beruf');scan:SetScript('OnClick',scanProfession)
  local clearFilters=CreateFrame('Button',nil,w,'UIPanelButtonTemplate')
  clearFilters:SetSize(104,23);clearFilters:SetPoint('LEFT',ignored,'RIGHT',8,0)
  clearFilters:SetText('Filter loeschen')
  local cols={
    {key='skill',title='',x=0,width=26},
    {key='name',title='Gegenstand',x=28,width=218},
    {key='cost',title='Material',x=248,width=115},
    {key='profit',title='Gewinn',x=365,width=115},
    {key='gross',title='AH-Erlös',x=482,width=115},
    {key='prof',title='Beruf',x=599,width=115},
    {key='char',title='Charakter',x=716,width=125},
  }
  local headers={}
  for _,col in ipairs(cols) do
    local c=col
    local h=CreateFrame('Button',nil,w)
    h:SetSize(c.width,23);h:SetPoint('TOPLEFT',w,'TOPLEFT',22+c.x,-112)
    h.label=h:CreateFontString(nil,'OVERLAY','GameFontNormalSmall')
    h.label:SetAllPoints();h.label:SetJustifyH('LEFT')
    h:SetHighlightTexture('Interface\\QuestFrame\\UI-QuestTitleHighlight')
    h:SetScript('OnClick',function()
      if DB.ui.sort==c.key then DB.ui.desc=not DB.ui.desc else DB.ui.sort=c.key;DB.ui.desc=(c.key=='cost' or c.key=='profit' or c.key=='gross') end
      w.refresh()
    end)
    local arrow=CreateFrame('Button',nil,h,'UIPanelButtonTemplate')
    arrow:SetSize(c.key=='skill' and 16 or 20,19);arrow:SetPoint('RIGHT',h,'RIGHT',-2,0)
    arrow:SetText('v')
    makeDropdown(arrow,function()
      local choices={}
      local values={}
      local seen={}
      if c.key=='cost' or c.key=='profit' or c.key=='gross' then
        values={'Unbekannt','Negativ','Null','Unter 1 Gold','1 bis 10 Gold','10 bis 100 Gold','Ab 100 Gold'}
      elseif c.key=='name' then values={'Gelernt','Nicht gelernt'}
      elseif c.key=='skill' then values={'Unbekannt','0','1','2','3'}
      else
        for char,ch in pairs(DB.characters) do
          if (ch.realm or char:match('%-(.+)$') or '')==realmKey() then
            if c.key=='char' then seen[char]=true
            else for _,prof in pairs(ch.professions or {}) do if prof.name then seen[prof.name]=true end end end
          end
        end
        for value in pairs(seen) do values[#values+1]=value end
        table.sort(values)
      end
      local selected=DB.ui.columnFilters[c.key] or {}
      choices[#choices+1]={label='Alle anzeigen / Filter leeren',value='__clear'}
      for _,value in ipairs(values) do
        choices[#choices+1]={label=(selected[tostring(value)] and '[x] ' or '[ ] ')..(c.key=='char' and (value:match('^[^-]+') or value) or tostring(value)),value=tostring(value)}
      end
      return choices
    end,function(value)
      if value=='__clear' then DB.ui.columnFilters[c.key]=nil
      else
        local f=DB.ui.columnFilters[c.key] or {}
        f[value]=not f[value] or nil
        DB.ui.columnFilters[c.key]=f
      end
      w.refresh()
      return true
    end)
    headers[#headers+1]={button=h,col=c}
  end
  local scroll=CreateFrame('ScrollFrame',nil,w,'FauxScrollFrameTemplate')
  scroll:SetPoint('TOPLEFT',w,'TOPLEFT',18,-138)
  scroll:SetPoint('BOTTOMRIGHT',w,'BOTTOMRIGHT',-30,37)
  local viewCount=24
  local rowHeight=22
  for i=1,viewCount do
    local b=CreateFrame('Button',nil,w)
    local shade=b:CreateTexture(nil,'BACKGROUND');shade:SetAllPoints()
    b.shade=shade;b.index=i
    b:SetHeight(rowHeight);b:SetPoint('TOPLEFT',w,'TOPLEFT',20,-139-(i-1)*rowHeight)
    b:SetPoint('RIGHT',w,'RIGHT',-38,0)
    b:SetHighlightTexture('Interface\\QuestFrame\\UI-QuestTitleHighlight')
    b.cells={}
    b.itemIcon=b:CreateTexture(nil,'ARTWORK')
    b.itemIcon:SetSize(17,17);b.itemIcon:SetPoint('TOPLEFT',b,'TOPLEFT',30,-2)
    for _,col in ipairs(cols) do
      local t=b:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
      t:SetPoint('TOPLEFT',b,'TOPLEFT',2+col.x+(col.key=='name' and 21 or 0),-4)
      t:SetWidth(col.width-7-(col.key=='name' and 21 or 0));t:SetHeight(17);t:SetJustifyH('LEFT')
      t:SetWordWrap(false)
      if col.key=='skill' then t:SetJustifyH('RIGHT') end
      b.cells[col.key]=t
    end
    b:SetScript('OnClick',function(self)
      if IsControlKeyDown() and self.entry then
        local k=self.entry.key
        DB.ignored[k]=DB.ignored[k] and nil or true
        w.refresh()
      elseif IsShiftKeyDown() and self.entry then
        openRecipe(self.entry)
      elseif self.entry then
        showMaterials(self.entry)
      end
    end)
    b:SetScript('OnEnter',function(self)
      local e=self.entry
      if not e then return end
      GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
      if e.rec.outputID and GameTooltip.SetHyperlink then GameTooltip:SetHyperlink('item:'..e.rec.outputID) else GameTooltip:AddLine(e.rec.name or '?') end
      if e.rec.learned==false and e.requiredSkill then GameTooltip:AddLine('Benötigter Skill: '..e.requiredSkill,1,.82,.2) end
      GameTooltip:AddLine('Material: '..money(e.cost)..' | AH-Erlös: '..money(e.gross),1,1,1)
      GameTooltip:AddLine('Gewinn: '..money(e.profit),.4,1,.4)
      if e.reason then GameTooltip:AddLine(e.reason,1,.5,.3) end
      for _,slot in ipairs(e.rec.reagents or {}) do
        local names={}
        for _,id in ipairs(slot.options or {}) do
          local p,src=cheapest(id)
          names[#names+1]=(getItemName(id) or ('ID '..id))..' ('..money(p)..' '..src..')'
        end
        GameTooltip:AddLine(tostring(slot.qty)..'x '..table.concat(names,' / '),.7,.7,.7)
      end
      GameTooltip:AddLine('Klick: Materialien | Shift: Berufsfenster | Strg: '..(DB.ignored[e.key] and 'wieder anzeigen' or 'ignorieren'),.5,.8,1)
      GameTooltip:Show()
    end)
    b:SetScript('OnLeave',function() GameTooltip:Hide() end)
    rows[i]=b
  end
  local data={}
  local function render()
    data=results()
    for _,h in ipairs(headers) do
      local c=h.col
      h.button.label:SetText(c.title..((DB.ui.columnFilters[c.key] and next(DB.ui.columnFilters[c.key])) and ' *' or '')..(DB.ui.sort==c.key and (DB.ui.desc and ' v' or ' ^') or ''))
    end
    ignored:SetText(DB.ui.showIgnored and 'Ignorierte: Ein' or 'Ignorierte: Aus')
    filter:SetText('Beruf: '..(DB.ui.filter or 'Alle'))
    viewCount=math.min(#rows,math.max(1,math.floor((w:GetHeight()-181)/rowHeight)))
    FauxScrollFrame_Update(scroll,#data,viewCount,rowHeight)
    local offset=FauxScrollFrame_GetOffset(scroll)
    for i,b in ipairs(rows) do
      local e=i<=viewCount and data[i+offset] or nil
      b.entry=e
      if e then
        if e.profit and e.profit<0 then
          b.shade:SetColorTexture(.72,.17,.13,.32)
        elseif i%2==0 then b.shade:SetColorTexture(.52,.38,.23,.20)
        else b.shade:SetColorTexture(.66,.53,.34,.13) end
        local difficulty=e.rec.relativeDifficulty
        local skillColors={[1]='|cff40cc40',[2]='|cffffff00',[3]='|cffff8040'}
        b.cells.skill:SetText(difficulty and skillColors[difficulty] and (skillColors[difficulty]..'●|r') or '')
        local nameColor=(e.skillTooLow or e.rec.unlearnable) and '|cffff4040' or (e.rec.learned==false and '|cffffff00' or '|cffffffff')
        b.cells.name:SetText(nameColor..(e.rec.name or '?')..'|r')
        local itemIcon=(e.rec.outputID and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(e.rec.outputID)) or e.rec.icon
        b.itemIcon:SetTexture(itemIcon or 'Interface\\Icons\\INV_Misc_QuestionMark')
        b.itemIcon:Show()
        b.cells.cost:SetText(money(e.cost))
        b.cells.profit:SetText((e.profit and (e.profit<0 and '|cffff6060' or '|cff55dd88') or '')..money(e.profit)..'|r')
        b.cells.gross:SetText(money(e.gross))
        b.cells.prof:SetText(e.prof or '?')
        b.cells.char:SetText(e.char:match('^[^-]+') or e.char)
        b:Show()
      else b.itemIcon:Hide();b:Hide() end
    end
    local missing=checkDependencies()
    hint:SetText(#missing>0 and ('|cffff6666'..table.concat(missing,' | ')..'|r') or '')
    updateFreshness()
  end
  makeDropdown(filter,function()
    local names={};local found={}
    for _,ch in pairs(DB.characters) do
      for _,prof in pairs(ch.professions or {}) do
        if prof.name and not found[prof.name] then found[prof.name]=true;names[#names+1]=prof.name end
      end
    end
    table.sort(names)
    local choices={{label='Alle',value='Alle'}}
    for _,name in ipairs(names) do choices[#choices+1]={label=name,value=name} end
    return choices
  end,function(value) DB.ui.filter=value;resultsDirty=true;render() end)
  -- Hierarchisches Dropdown statt eines eigenen Datenbankfensters.
  local function confirmDelete(message,callback)
    StaticPopupDialogs['FCP_CONFIRM_DELETE']={text=message,button1=YES,button2=NO,
      OnAccept=function() callback();priceCache={};DB.ui.columnFilters={};invalidateRecipes();render() end,
      timeout=0,whileDead=true,hideOnEscape=true,preferredIndex=3}
    StaticPopup_Show('FCP_CONFIRM_DELETE')
  end
  local function sortedChars()
    local t={};for name,ch in pairs(DB.characters) do if (ch.realm or name:match('%-(.+)$') or '')==realmKey() then t[#t+1]=name end end
    table.sort(t);return t
  end
  databaseOptions=function()
    local out={
      {label='< Optionen',value='options'},
      {label='Charakter loeschen  >',value='characters'},
      {label='Beruf loeschen  >',value='professions'},
      {label='Alle Rezeptdaten loeschen',value='all'},
      {label='Ignorierliste leeren',value='ignored'},
    }
    if dbMenu=='characters' or dbMenu=='professions' then
      out={{label='< Zurueck',value='root'}}
      for _,char in ipairs(sortedChars()) do
        out[#out+1]={label=(char:match('^[^-]+') or char)..(dbMenu=='professions' and '  >' or ''),value='char:'..char}
      end
    elseif dbMenu and dbMenu:sub(1,5)=='prof:' then
      local char=dbMenu:sub(6)
      out={{label='< Zurueck',value='professions'}}
      local ch=DB.characters[char]
      if ch then
        local names={}
        for k,p in pairs(ch.professions or {}) do names[#names+1]={key=k,name=p.name or tostring(k)} end
        table.sort(names,function(a,b) return a.name<b.name end)
        for _,p in ipairs(names) do out[#out+1]={label=p.name,value='deleteprof:'..char..'|'..p.key} end
      end
    end
    return out
  end
  chooseDB=function(value)
    if value=='options' then dbMenu=nil
    elseif value=='root' then dbMenu='root'
    elseif value=='characters' or value=='professions' then dbMenu=value
    elseif value:sub(1,5)=='char:' then
      local char=value:sub(6)
      if dbMenu=='professions' then dbMenu='prof:'..char
      else
        confirmDelete('Alle gespeicherten Berufe von '..(char:match('^[^-]+') or char)..' loeschen?',function() DB.characters[char]=nil end)
      end
    elseif value:sub(1,11)=='deleteprof:' then
      local char,key=value:sub(12):match('^(.-)|(.+)$')
      local ch=char and DB.characters[char]
      local p=ch and ch.professions[key]
      if p then confirmDelete('Beruf '..(p.name or key)..' von '..(char:match('^[^-]+') or char)..' loeschen?',function()
        if DB.characters[char] then DB.characters[char].professions[key]=nil end
      end) end
    elseif value=='all' then
      confirmDelete('Alle FCP-Rezeptdaten dieser Spielwelt loeschen?',function() for name,ch in pairs(DB.characters) do if (ch.realm or name:match('%-(.+)$') or '')==realmKey() then DB.characters[name]=nil end end;DB.trainerSkills[realmKey()]=nil end)
    elseif value=='ignored' then
      confirmDelete('Gesamte FCP-Ignorierliste leeren?',function() DB.ignored={} end)
    end
    return value=='options' or value=='root' or value=='characters' or value=='professions' or (value:sub(1,5)=='char:' and dbMenu=='prof:'..value:sub(6))
  end
  -- Database navigation is integrated into the Options dropdown.
  clearFilters:SetScript('OnClick',function() DB.ui.search='';DB.ui.filter='Alle';DB.ui.profFilter='Alle';DB.ui.charFilter='Alle';DB.ui.onlyProfit=false;DB.ui.columnFilters={};DB.ui.showIgnored=false;DB.ui.sort='profit';DB.ui.desc=true;search:SetText('');resultsDirty=true;render() end)
  ignored:SetScript('OnClick',function() DB.ui.showIgnored=not DB.ui.showIgnored;resultsDirty=true;render() end)
  scroll:SetScript('OnVerticalScroll',function(self,offset) FauxScrollFrame_OnVerticalScroll(self,offset,rowHeight,render) end)
  refresh:SetScript('OnClick',function() invalidatePrices();render() end)
  w.refresh=function() resultsDirty=true;cachedResults=nil;render() end;UI=w
end
local fcpProfessionButton
local function attachProfessionButton()
  local parent=_G.ProfessionsFrame or _G.ProfessionsBookFrame or _G.TradeSkillFrame
  if not parent or not parent.IsShown or not parent:IsShown() then
    if fcpProfessionButton then fcpProfessionButton:Hide() end
    return
  end
  if not fcpProfessionButton then
    -- Gleiche native Seitentab-Vorlage wie Talents Forever, aber im Berufsfenster.
    local host=(parent.rightProfessionTabs and parent.rightProfessionTabs[1] and parent.rightProfessionTabs[1]:GetParent()) or parent
    local ok,tab=pcall(CreateFrame,'Frame','FCPProfessionButton',host,'LargeSideTabButtonTemplate')
    if ok and tab then
      fcpProfessionButton=tab
      tab.tooltipText='Forever Craft Profit'
      if tab.Icon then
        tab.Icon:SetTexture('Interface\\Icons\\INV_Misc_Coin_01')
        if tab.SetFillToInterior then tab:SetFillToInterior(true,50) end
      end
      local function toggle()
        if not DB then init() end
        if not UI then createUI() end
        if UI:IsShown() then UI:Hide() else UI.refresh();UI:Show() end
        if tab.SetChecked then tab:SetChecked(false) end
      end
      if tab.SetCustomOnMouseUpHandler then
        tab:SetCustomOnMouseUpHandler(function(_,button,inside) if button=='LeftButton' and inside then toggle() end end)
      else
        tab:SetScript('OnMouseUp',function(_,button) if button=='LeftButton' then toggle() end end)
      end
      tab:SetScript('OnEnter',function(self) GameTooltip:SetOwner(self,'ANCHOR_LEFT');GameTooltip:SetText('Forever Craft Profit',1,.82,0);GameTooltip:Show() end)
      tab:SetScript('OnLeave',function() GameTooltip:Hide() end)
    else
      -- Fallback, falls der Client die native Vorlage nicht besitzt.
      tab=CreateFrame('Button','FCPProfessionButton',host,'UIPanelButtonTemplate')
      tab:SetText('FCP')
      tab:SetScript('OnClick',function()
        if not DB then init() end
        if not UI then createUI() end
        if UI:IsShown() then UI:Hide() else UI.refresh();UI:Show() end
      end)
      fcpProfessionButton=tab
    end
  end
  fcpProfessionButton:ClearAllPoints()
  local tabs=parent.rightProfessionTabs
  local last
  if type(tabs)=='table' then
    for _,button in ipairs(tabs) do
      if button and button.IsShown and button:IsShown() then
        if not last or (button.GetBottom and last.GetBottom and button:GetBottom() and last:GetBottom() and button:GetBottom()<last:GetBottom()) then last=button end
      end
    end
  end
  if last then
    fcpProfessionButton:SetSize(last:GetWidth(),last:GetHeight())
    fcpProfessionButton:SetFrameStrata(parent:GetFrameStrata())
    fcpProfessionButton:SetFrameLevel(last:GetFrameLevel())
    fcpProfessionButton:SetScale(1)
    fcpProfessionButton:SetPoint('TOPLEFT',last,'BOTTOMLEFT',0,-2)
  else
    fcpProfessionButton:SetSize(42,42)
    fcpProfessionButton:SetPoint('TOPLEFT',parent,'TOPRIGHT',-3,-440)
  end
  fcpProfessionButton:Show()
end
local function command(msg)
  local op=(msg or ''):match('^%s*(%S+)') or ''
  op=op:lower()
  if not DB then init() end
  if op=='scan' then
    FCPScanName=(msg or ''):match('^%s*%S+%s+(.+)%s*$')
    F.manualScan=true;scanProfession()
    FCPScanName=nil
  elseif op=='autoscan' then DB.settings.autoScan=not DB.settings.autoScan;log('Automatischer Berufsscan: '..(DB.settings.autoScan and 'Ein' or 'Aus'))
  elseif op=='position' and (msg or ''):find('reset') then
    DB.ui.x=nil;DB.ui.y=nil;DB.ui.width=970;DB.ui.height=535
    if UI then UI:ClearAllPoints();UI:SetPoint('CENTER',UIParent,'CENTER',0,0);UI:SetSize(970,535) end
    if materialWindow then materialWindow:ClearAllPoints();materialWindow:SetPoint('CENTER',UIParent,'CENTER',-130,20) end
    log('Fensterposition und -groesse zurueckgesetzt.')
  elseif op=='debug' then
    log('Diagnose: Beruf='..tostring(C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillLine and C_TradeSkillUI.GetTradeSkillLine()))
    log('Auctionator='..tostring(_G.Auctionator~=nil)..', Syndicator='..tostring(_G.Syndicator~=nil))
    log('Skillpunkte: relativeDifficulty 1-3; Zuordnung im Client pruefen. AH-Kaution: API noch nicht verifiziert.')
    elseif op=='help' then
    log('/fcp | /fcp scan [Beruf] | /fcp refresh | /fcp autoscan | /fcp position reset | /fcp debug | /fcp help')
  elseif op=='refresh' then invalidatePrices(); if UI then UI.refresh() end; log('AH-Preise neu gelesen.')
  else
    if not UI then createUI() end
    if UI:IsShown() then UI:Hide() else invalidatePrices(); UI.refresh(); UI:Show() end
  end
end
SLASH_FOREVERCRAFTPROFIT1='/fcp'
SlashCmdList.FOREVERCRAFTPROFIT=command
F:RegisterEvent('ADDON_LOADED')
F:RegisterEvent('PLAYER_LOGIN')
F:RegisterEvent('TRADE_SKILL_SHOW')
F:RegisterEvent('TRADE_SKILL_LIST_UPDATE')
F:RegisterEvent('TRAINER_SHOW')
F:RegisterEvent('TRAINER_UPDATE')
F:SetScript('OnEvent',function(self,event,arg)
  if event=='ADDON_LOADED' and arg==ADDON then init()
  elseif event=='PLAYER_LOGIN' then
    if not DB then init() end
    log('v'..VERSION..' geladen. /fcp help')
    if _G.ProfessionsFrame then
      _G.ProfessionsFrame:HookScript('OnShow',attachProfessionButton)
      _G.ProfessionsFrame:HookScript('OnHide',attachProfessionButton)
    end
    checkDependencies()
  elseif event=='TRADE_SKILL_SHOW' or event=='TRADE_SKILL_LIST_UPDATE' then
    attachProfessionButton()
    if DB and DB.settings.autoScan and event=='TRADE_SKILL_SHOW' and (not self.lastProfessionScan or GetTime()-self.lastProfessionScan>5) then
      self.lastProfessionScan=GetTime();scanProfession()
    end
  elseif event=='TRAINER_SHOW' or event=='TRAINER_UPDATE' then
    scanTrainer()
  end
end)
