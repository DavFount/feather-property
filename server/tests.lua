-- Development-only acceptance test. MUTATES DATA: it registers a uniquely keyed
-- smoke house, grants co-owners and tenancies (one expiring after a few
-- seconds), races two ownership transfers, suspends and retires the house.
-- Never enable DevMode in production.
--   Usage (server console):
--   PropertyLifecycleSmokeTest <serverId|characterUuid> <otherServerId|otherCharacterUuid>

local function Target(argument)
    if Property.Uuid(argument) then
        return argument:lower()
    end
    local source = tonumber(argument)
    if not source then
        return nil
    end
    local session = exports['feather-core']:GetSessionContext(source)
    return type(session) == 'table' and session.ok and session.value.characterId or nil
end

-- Runs both transfers at once; the property row lock must let exactly one win.
local function Race(first, second)
    local results, done = {}, 0
    for index, request in ipairs({ first, second }) do
        CreateThread(function()
            results[index] = PropertyInterests.Transfer(request, GetCurrentResourceName())
            done = done + 1
        end)
    end
    while done < 2 do
        Wait(0)
    end
    return results[1], results[2]
end

Property.RegisterDevCommand('PropertyLifecycleSmokeTest', function(source, args)
    if source ~= 0 then
        return
    end
    local called, reason = xpcall(function()
        local holderA, holderB = Target(args[1]), Target(args[2])
        if not holderA or not holderB or holderA == holderB then
            print('[PropertyLifecycleSmokeTest] usage: PropertyLifecycleSmokeTest <serverId|characterUuid> <otherServerId|otherCharacterUuid>')
            return
        end
        local owner, untrusted = GetCurrentResourceName(), 'untrusted-smoke-caller'
        local run = ('%d%04d'):format(os.time(), math.random(0, 9999))
        local reasonCode = 'property.smoke_test'
        local key = 'feather-property:smoke' .. run
        local function Id(step)
            return ('smoke:%s:%s'):format(run, step)
        end
        local function Register(requestId, propertyKey, label, resource)
            return PropertyRecords.Register({
                requestId = requestId,
                propertyKey = propertyKey,
                propertyType = 'house',
                label = label,
                maxOwners = 2,
                maxTenants = 1,
                reasonCode = reasonCode
            }, resource)
        end
        local propertyId = '00000000-0000-0000-0000-000000000000'
        local function Grant(step, revision, holderId, interestType, validUntil)
            return PropertyInterests.Grant({
                requestId = Id(step),
                propertyId = propertyId,
                expectedRevision = revision,
                holderType = 'character',
                holderId = holderId,
                interestType = interestType,
                validUntil = validUntil,
                reasonCode = reasonCode
            }, owner)
        end
        local function Check(holderId, interestType)
            return PropertyInterests.Check({ propertyId = propertyId, holderType = 'character',
                holderId = holderId, interestType = interestType }, owner)
        end

        local registered = Register(Id('register'), key, 'Smoke House', owner)
        local replayed = Register(Id('register'), key, 'Smoke House', owner)
        local conflicted = Register(Id('register'), key, 'Other Label', owner)
        local duplicate = Register(Id('register-again'), key, 'Smoke House', owner)
        local denied = Register(Id('denied'), key .. 'x', 'Smoke House', untrusted)
        local badKey = Register(Id('bad-key'), 'no namespace', 'Smoke House', owner)
        propertyId = registered.ok and registered.value.propertyId or propertyId

        local ownerA = Grant('owner-a', 1, holderA, 'owner')
        local ownerAgain = Grant('owner-a-again', 2, holderA, 'owner')
        local ownerB = Grant('owner-b', 2, holderB, 'owner')
        local nowMs = os.time() * 1000
        local tenantA = Grant('tenant-a', 3, holderA, 'tenant', nowMs + 3000)
        local tenantBefore = Check(holderA, 'tenant')
        Wait(4500)
        local tenantAfter = Check(holderA, 'tenant')
        -- The expiry sweep may have ended the tenancy meanwhile (bumping the
        -- revision), so continue from the current revision.
        local current = PropertyRecords.Get({ propertyId = propertyId }, owner)
        local r = current.ok and current.value.revision or 4
        local tenantB = Grant('tenant-b', r, holderB, 'tenant')
        local tenantFull = Grant('tenant-a-full', r + 1, holderA, 'tenant')

        local function Transfer(step, revision, extra)
            local request = {
                requestId = Id(step),
                propertyId = propertyId,
                expectedRevision = revision,
                toHolderType = 'character',
                toHolderId = holderA,
                reasonCode = reasonCode
            }
            for field, value in pairs(extra or {}) do
                request[field] = value
            end
            return request
        end
        local stale = PropertyInterests.Transfer(Transfer('transfer-stale', 99), owner)
        local mismatch = PropertyInterests.Transfer(Transfer('transfer-mismatch', r + 1, {
            fromHolderType = 'organization',
            fromHolderId = '00000000-0000-0000-0000-000000000001'
        }), owner)
        local raceA, raceB = Race(Transfer('race-a', r + 1), Transfer('race-b', r + 1))
        local winners = (raceA.ok and 1 or 0) + (raceB.ok and 1 or 0)
        local loser = raceA.ok and raceB or raceA
        local won = raceA.ok and raceA or raceB

        local ownerCheckA = Check(holderA, 'owner')
        local ownerCheckB = Check(holderB, 'owner')
        local tenantKept = Check(holderB, 'tenant')
        local listedB = PropertyRecords.ListByHolder({ holderType = 'character', holderId = holderB }, owner)
        local listedHas = false
        for _, item in ipairs(listedB.ok and listedB.value.items or {}) do
            if item.propertyId == propertyId then
                listedHas = true
            end
        end

        local tenantInterest = won.ok and won.value.tenants[1] and won.value.tenants[1].interestId or propertyId
        local ended = PropertyInterests.End({ requestId = Id('end-tenant'), propertyId = propertyId,
            expectedRevision = r + 2, interestId = tenantInterest, reasonCode = reasonCode }, owner)
        local endedAgain = PropertyInterests.End({ requestId = Id('end-tenant-again'), propertyId = propertyId,
            expectedRevision = r + 3, interestId = tenantInterest, reasonCode = reasonCode }, owner)
        local renamed = PropertyRecords.UpdateMetadata({ requestId = Id('rename'), propertyId = propertyId,
            expectedRevision = r + 3, label = 'Renamed House', reasonCode = reasonCode }, owner)
        local suspended = PropertyRecords.ChangeStatus({ requestId = Id('suspend'), propertyId = propertyId,
            expectedRevision = r + 4, status = 'suspended', reasonCode = reasonCode }, owner)
        local suspendedGrant = Grant('suspended-grant', r + 5, holderB, 'tenant')
        local foreign = PropertyRecords.ChangeStatus({ requestId = Id('retire-foreign'), propertyId = propertyId,
            expectedRevision = r + 5, status = 'retired', reasonCode = reasonCode }, untrusted)
        local retired = PropertyRecords.ChangeStatus({ requestId = Id('retire'), propertyId = propertyId,
            expectedRevision = r + 5, status = 'retired', reasonCode = reasonCode }, owner)
        local retiredAgain = PropertyRecords.ChangeStatus({ requestId = Id('retire-again'), propertyId = propertyId,
            expectedRevision = r + 6, status = 'active', reasonCode = reasonCode }, owner)
        local checkAfter = Check(holderA, nil)
        local byKey = PropertyRecords.FindByKey({ propertyKey = key }, owner)
        local lookup = Property.FindOperation({ requestId = Id('register') }, owner)
        local history = PropertyEvents.History({ propertyId = propertyId, limit = 50 }, owner)

        local tests = {
            { 'register property', registered.ok and registered.value.revision == 1
                and #registered.value.owners == 0 and registered.value.replayed == false },
            { 'idempotent replay', replayed.ok and replayed.value.replayed == true
                and replayed.value.propertyId == propertyId },
            { 'idempotency conflict', not conflicted.ok and conflicted.code == 'idempotency_conflict' },
            { 'duplicate key', not duplicate.ok and duplicate.code == 'property_exists' },
            { 'untrusted manager denied', not denied.ok and denied.code == 'authorization_denied' },
            { 'key must be namespaced', not badKey.ok and badKey.code == 'invalid_input' },
            { 'grant owner', ownerA.ok and #ownerA.value.owners == 1 and ownerA.value.revision == 2 },
            { 'duplicate interest', not ownerAgain.ok and ownerAgain.code == 'interest_exists' },
            { 'co-owner', ownerB.ok and #ownerB.value.owners == 2 },
            { 'tenancy granted', tenantA.ok and tenantA.value.tenants[1] ~= nil
                and tenantA.value.tenants[1].validUntil ~= nil },
            { 'tenancy effective', tenantBefore.ok and tenantBefore.value.matched == true },
            { 'tenancy expires', tenantAfter.ok and tenantAfter.value.matched == false },
            { 'expired slot reused', tenantB.ok and #tenantB.value.tenants == 1
                and tenantB.value.tenants[1].holderId == holderB },
            { 'tenant cap enforced', not tenantFull.ok and tenantFull.code == 'interest_limit' },
            { 'stale revision rejected', not stale.ok and stale.code == 'revision_conflict' },
            { 'holder mismatch rejected', not mismatch.ok and mismatch.code == 'holder_mismatch' },
            { 'concurrent sale one winner', winners == 1 and loser.code == 'revision_conflict' },
            { 'new sole owner', ownerCheckA.ok and ownerCheckA.value.matched == true
                and won.ok and #won.value.owners == 1 },
            { 'co-owner released', ownerCheckB.ok and ownerCheckB.value.matched == false },
            { 'tenancy kept on sale', tenantKept.ok and tenantKept.value.matched == true },
            { 'listed under tenant', listedHas },
            { 'end interest', ended.ok and #ended.value.tenants == 0 },
            { 'end twice rejected', not endedAgain.ok and endedAgain.code == 'interest_not_found' },
            { 'label revised', renamed.ok and renamed.value.label == 'Renamed House' },
            { 'suspended', suspended.ok and suspended.value.status == 'suspended' },
            { 'suspended gains nothing', not suspendedGrant.ok and suspendedGrant.code == 'property_unavailable' },
            { 'foreign mutation denied', not foreign.ok and foreign.code == 'authorization_denied' },
            { 'retired ends interests', retired.ok and retired.value.status == 'retired'
                and #retired.value.owners == 0 },
            { 'retire is terminal', not retiredAgain.ok and retiredAgain.code == 'property_retired' },
            { 'no interest after retire', checkAfter.ok and checkAfter.value.matched == false
                and checkAfter.value.propertyStatus == 'retired' },
            { 'find by key', byKey.ok and byKey.value.propertyId == propertyId },
            { 'operation lookup', lookup.ok and lookup.value.found == true
                and lookup.value.operation == 'property.register' },
            { 'audit history', history.ok and #history.value.items == 12 }
        }
        local passed = 0
        for _, test in ipairs(tests) do
            if test[2] then
                passed = passed + 1
            end
            print(('[PropertyLifecycleSmokeTest] %-28s %s'):format(test[1], test[2] and 'PASS' or 'FAIL'))
        end
        print(('[PropertyLifecycleSmokeTest] done %d/%d passed (MUTATING: property %s)'):format(
            passed, #tests, propertyId))

        local function Explain(step, result)
            if result.ok then
                return
            end
            local details = type(result.details) == 'table' and result.details or {}
            print(('[PropertyLifecycleSmokeTest] %s failed code=%s policyCode=%s provider=%s reason=%s'):format(
                step, tostring(result.code), tostring(details.policyCode), tostring(details.provider),
                tostring(details.policyReason or result.message)))
        end
        Explain('register', registered)
        Explain('grant owner', ownerA)
        if winners == 0 then
            Explain('transfer', raceA)
        end
        if history.ok and #history.value.items ~= 12 then
            print(('[PropertyLifecycleSmokeTest] history has %d events'):format(#history.value.items))
        end
    end, debug.traceback)
    if not called then
        print('[PropertyLifecycleSmokeTest] FAIL ' .. tostring(reason))
    end
end, true)
