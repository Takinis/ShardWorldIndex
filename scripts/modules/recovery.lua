local function choose_candidate(candidates, transaction)
    local selected = nil
    for _, candidate in ipairs(candidates or {}) do
        if selected == nil then
            selected = candidate
        elseif transaction ~= nil and transaction.IsNewer(candidate.state, selected.state) then
            selected = candidate
        elseif transaction == nil then
            local left_time = tonumber(candidate.state ~= nil and candidate.state.updated_at or nil) or 0
            local right_time = tonumber(selected.state ~= nil and selected.state.updated_at or nil) or 0
            if left_time > right_time or
                left_time == right_time and tostring(candidate.file_id) < tostring(selected.file_id) then
                selected = candidate
            end
        end
    end
    return selected
end

local function sort_file_ids(file_ids)
    local ids = {}
    for _, file_id in ipairs(file_ids or {}) do
        ids[#ids + 1] = tostring(file_id)
    end
    table.sort(ids)
    return ids
end

return
{
    ChooseCandidate = choose_candidate,
    SortFileIDs = sort_file_ids,
}
