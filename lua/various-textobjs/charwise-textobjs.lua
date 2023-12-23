local M = {}
local fn = vim.fn
local bo = vim.bo
local u = require("various-textobjs.utils")
--------------------------------------------------------------------------------

---@return boolean
local function isVisualMode()
	local modeWithV = vim.fn.mode():find("v")
	return modeWithV ~= nil
end

---@alias pos {[1]: integer, [2]: integer}

---sets the selection for the textobj (characterwise)
---@param startPos pos
---@param endPos pos
local function setSelection(startPos, endPos)
	u.setCursor(0, startPos)
	if isVisualMode() then
		u.normal("o")
	else
		u.normal("v")
	end
	u.setCursor(0, endPos)
end

--------------------------------------------------------------------------------

---Seek and select characterwise text object based on pattern.
---@param pattern string lua pattern. REQUIRES two capture groups marking the
---two additions for the outer variant of the textobj. Use an empty capture group
---when there is no difference between inner and outer on that side.
---(Essentially, the two capture groups work as lookbehind and lookahead.)
---CAVEAT multi-line-objects are not supported
---@param scope "inner"|"outer"
---@param lookForwL integer
---@return pos? startPos
---@return pos? endPos
---@nodiscard
local function searchTextobj(pattern, scope, lookForwL)
	local cursorRow, cursorCol = unpack(u.getCursor(0))
	local lineContent = u.getline(cursorRow)
	local lastLine = vim.api.nvim_buf_line_count(0)
	local beginCol = 0 ---@type number|nil
	local endCol, captureG1, captureG2, noneInStartingLine

	-- first line: check if standing on or in front of textobj
	repeat
		beginCol = beginCol + 1
		beginCol, endCol, captureG1, captureG2 = lineContent:find(pattern, beginCol)
		noneInStartingLine = not beginCol
		local standingOnOrInFront = endCol and endCol > cursorCol
	until standingOnOrInFront or noneInStartingLine

	-- subsequent lines: search full line for first occurrence
	local linesSearched = 0
	if noneInStartingLine then
		while true do
			linesSearched = linesSearched + 1
			if linesSearched > lookForwL or cursorRow + linesSearched > lastLine then return end
			lineContent = u.getline(cursorRow + linesSearched)

			beginCol, endCol, captureG1, captureG2 = lineContent:find(pattern)
			if beginCol then break end
		end
	end

	-- capture groups determine the inner/outer difference
	-- INFO :find() returns integers of the position if the capture group is empty
	if scope == "inner" then
		local frontOuterLen = type(captureG1) ~= "number" and #captureG1 or 0
		local backOuterLen = type(captureG2) ~= "number" and #captureG2 or 0
		beginCol = beginCol + frontOuterLen
		endCol = endCol - backOuterLen
	end

	local startPos = { cursorRow + linesSearched, beginCol - 1 }
	local endPos = { cursorRow + linesSearched, endCol - 1 }
	return startPos, endPos
end

---searches for the position of one or multiple patterns and selects the closest one
---@param patterns string|string[] lua, pattern(s) with the specification from `searchTextobj`
---@param scope "inner"|"outer" true = inner textobj
---@param lookForwL integer
---@return boolean -- whether textobj search was successful
local function selectTextobj(patterns, scope, lookForwL)
	local closestObj
	if type(patterns) == "string" then
		local startPos, endPos = searchTextobj(patterns, scope, lookForwL)
		if startPos and endPos then closestObj = { startPos, endPos } end
	elseif type(patterns) == "table" then
		local closestRow = math.huge
		local shortestDistance = math.huge
		for _, pattern in ipairs(patterns) do
			local startPos, endPos = searchTextobj(pattern, scope, lookForwL)
			if startPos and endPos then
				local row, col = unpack(startPos)
				local cursorRow, cursorCol = unpack(u.getCursor(0))
				local cursorStandsOnObj = (cursorRow == row and col <= cursorCol)
				local distance = cursorStandsOnObj and math.abs(col - cursorCol) or col - cursorCol
				if row <= closestRow and distance < shortestDistance then
					closestRow = row
					shortestDistance = distance
					closestObj = { startPos, endPos }
				end
			end
		end
	end

	if closestObj then
		local startPos, endPos = unpack(closestObj)
		setSelection(startPos, endPos)
		return true
	else
		u.notFoundMsg(lookForwL)
		return false
	end
end

--------------------------------------------------------------------------------

---@param scope "inner"|"outer" outer includes trailing -_
function M.subword(scope)
	local pattern = {
		"()%w[%l%d]+([_%- ]?)", -- camelCase or lowercase
		"()[%u%d]+([_%- ]?)", -- UPPER_CASE or digits
	}
	selectTextobj(pattern, scope, 0)
end

---@param lookForwL integer
function M.toNextClosingBracket(lookForwL)
	local pattern = "().([]})])"

	local _, endPos = searchTextobj(pattern, "inner", lookForwL)
	if not endPos then
		u.notFoundMsg(lookForwL)
		return
	end
	local startPos = u.getCursor(0)

	setSelection(startPos, endPos)
end

---@param lookForwL integer
function M.toNextQuotationMark(lookForwL)
	-- char before quote must not be escape char. Using `vim.opt.quoteescape` on
	-- the off-chance that the user has customized this.
	local quoteEscape = vim.opt_local.quoteescape:get() -- default: \
	local pattern = ([[()[^%s](["'`])]]):format(quoteEscape)

	local _, endPos = searchTextobj(pattern, "inner", lookForwL)
	if not endPos then
		u.notFoundMsg(lookForwL)
		return
	end
	local startPos = u.getCursor(0)

	setSelection(startPos, endPos)
end

---@param scope "inner"|"outer"
---@param lookForwL integer
function M.anyQuote(scope, lookForwL)
	-- INFO char before quote must not be escape char. Using `vim.opt.quoteescape` on
	-- the off-chance that the user has customized this.
	local escape = vim.opt_local.quoteescape:get() -- default: \
	local patterns = {
		('([^%s]").-[^%s](")'):format(escape, escape),
		("([^%s]').-[^%s](')"):format(escape, escape),
		("([^%s]`).-[^%s](`)"):format(escape, escape),
	}

	selectTextobj(patterns, scope, lookForwL)

	-- pattern includes one extra character to account for an escape character,
	-- so we need to move to the right to factor that in
	if scope == "outer" then u.normal("ol") end
end

---near end of the line, ignoring trailing whitespace
---(relevant for markdown, where you normally add a -space after the `.` ending a sentence.)
function M.nearEoL()
	if not isVisualMode() then u.normal("v") end
	u.normal("$")

	-- loop ensures trailing whitespace is not omitted
	local lineContent = vim.api.nvim_get_current_line()
	local lastCol = vim.api.nvim_buf_line_count(0)
	repeat
		u.normal("h")
		lastCol = lastCol - 1
		local lastChar = lineContent:sub(lastCol, lastCol)
	until not lastChar:find("%s") or lastCol == 1

	u.normal("h")
end

---current line (but characterwise)
---@param scope "inner"|"outer" outer includes indentation and trailing spaces
function M.lineCharacterwise(scope)
	-- edge case: empty line
	if fn.col("$") == 1 then return end

	if not isVisualMode() then u.normal("v") end
	if scope == "inner" then
		u.normal("g_o^")
	else
		u.normal("$ho0")
	end
end

---similar to https://github.com/andrewferrier/textobj-diagnostic.nvim
---requires builtin LSP
---@param lookForwL integer
function M.diagnostic(lookForwL)
	-- INFO for whatever reason, diagnostic line numbers and the end column (but
	-- not the start column) are all off-by-one…

	-- HACK if cursor is standing on a diagnostic, get_prev() will return that
	-- diagnostic *BUT* only if the cursor is not on the first character of the
	-- diagnostic, since the columns checked seem to be off-by-one as well m(
	-- Therefore counteracted by temporarily moving the cursor
	u.normal("l")
	local prevD = vim.diagnostic.get_prev { wrap = false }
	u.normal("h")

	local nextD = vim.diagnostic.get_next { wrap = false }
	local curStandingOnPrevD = false -- however, if prev diag is covered by or before the cursor has yet to be determined
	local curRow, curCol = unpack(u.getCursor(0))

	if prevD then
		local curAfterPrevDstart = (curRow == prevD.lnum + 1 and curCol >= prevD.col)
			or (curRow > prevD.lnum + 1)
		local curBeforePrevDend = (curRow == prevD.end_lnum + 1 and curCol <= prevD.end_col - 1)
			or (curRow < prevD.end_lnum)
		curStandingOnPrevD = curAfterPrevDstart and curBeforePrevDend
	end

	local target
	if curStandingOnPrevD then
		target = prevD
	elseif nextD and (curRow + lookForwL > nextD.lnum) then
		target = nextD
	end
	if not target then
		u.notFoundMsg(lookForwL)
		return
	end
	setSelection({ target.lnum + 1, target.col }, { target.end_lnum + 1, target.end_col - 1 })
end

---@param scope "inner"|"outer" inner value excludes trailing commas or semicolons, outer includes them. Both exclude trailing comments.
---@param lookForwL integer
function M.value(scope, lookForwL)
	-- captures value till the end of the line
	-- negative sets and frontier pattern ensure that equality comparators ==, !=
	-- or css pseudo-elements :: are not matched
	local pattern = "(%s*%f[!<>~=:][=:]%s*)[^=:].*()"

	local valueFound = selectTextobj(pattern, scope, lookForwL)
	if not valueFound then return end

	-- if value found, remove trailing comment from it
	local curRow = u.getCursor(0)[1]
	local lineContent = u.getline(curRow)
	if bo.commentstring ~= "" then -- JSON has empty commentstring
		local commentPat = bo.commentstring:gsub(" ?%%s.*", "") -- remove placeholder and backside of commentstring
		commentPat = vim.pesc(commentPat) -- escape lua pattern
		commentPat = " *" .. commentPat .. ".*" -- to match till end of line
		lineContent = lineContent:gsub(commentPat, "") -- remove commentstring
	end
	local valueEndCol = #lineContent - 1

	-- inner value = exclude trailing comma/semicolon
	if scope == "inner" and lineContent:find("[,;]$") then valueEndCol = valueEndCol - 1 end

	u.setCursor(0, { curRow, valueEndCol })
end

---@param scope "inner"|"outer" outer key includes the `:` or `=` after the key
---@param lookForwL integer
function M.key(scope, lookForwL)
	local pattern = "(%s*).-( ?[:=] ?)"

	local valueFound = selectTextobj(pattern, scope, lookForwL)
	if not valueFound then return end

	-- 1st capture is included for the outer obj, but we don't want it
	if scope == "outer" then
		local curRow = u.getCursor(0)[1]
		local leadingWhitespace = u.getline(curRow):find("[^%s]") - 1
		u.normal("o")
		u.setCursor(0, { curRow, leadingWhitespace })
	end
end

---@param scope "inner"|"outer" inner number consists purely of digits, outer number factors in decimal points and includes minus sign
---@param lookForwL integer
function M.number(scope, lookForwL)
	-- here two different patterns make more sense, so the inner number can match
	-- before and after the decimal dot. enforcing digital after dot so outer
	-- excludes enumrations.
	local pattern = scope == "inner" and "%d+" or "%-?%d*%.?%d+"
	selectTextobj(pattern, "outer", lookForwL)
end

---@param lookForwL integer
function M.url(lookForwL)
	-- INFO mastodon URLs contain `@`, neovim docs urls can contain a `'`
	local pattern = "%l%l%l-://[A-Za-z0-9_%-/.#%%=?&'@+]+"
	selectTextobj(pattern, "outer", lookForwL)
end

---see #26
---@param scope "inner"|"outer" inner excludes the leading dot
---@param lookForwL integer
function M.chainMember(scope, lookForwL)
	local pattern = "(%.)[%w_][%a_]*%b()()"
	selectTextobj(pattern, scope, lookForwL)
end

--------------------------------------------------------------------------------
-- FILETYPE SPECIFIC TEXTOBJS

---@param scope "inner"|"outer" inner link only includes the link title, outer link includes link, url, and the four brackets.
---@param lookForwL integer
function M.mdlink(scope, lookForwL)
	local pattern = "(%[)[^%]]-(%]%b())"
	selectTextobj(pattern, scope, lookForwL)
end

---@param scope "inner"|"outer" inner double square brackets exclude the brackets themselves
---@param lookForwL integer
function M.doubleSquareBrackets(scope, lookForwL)
	local pattern = "(%[%[).-(%]%])"
	selectTextobj(pattern, scope, lookForwL)
end

---@param scope "inner"|"outer" outer selector includes trailing comma and whitespace
---@param lookForwL integer
function M.cssSelector(scope, lookForwL)
	local pattern = "()[#.][%w-_]+(,? ?)"
	selectTextobj(pattern, scope, lookForwL)
end

---@param scope "inner"|"outer" inner selector is only the value of the attribute inside the quotation marks.
---@param lookForwL integer
function M.htmlAttribute(scope, lookForwL)
	local pattern = [[(%w+=["']).-(["'])]]
	selectTextobj(pattern, scope, lookForwL)
end

---@param scope "inner"|"outer" outer selector includes the front pipe
---@param lookForwL integer
function M.shellPipe(scope, lookForwL)
	local pattern = "(| ?)[^|]+()"
	selectTextobj(pattern, scope, lookForwL)
end

---@param scope "inner"|"outer" inner excludes `"""`
function M.pyTripleQuotes(scope)
	local node = u.getNodeAtCursor()
	if not node then
		u.notify("No node found.", "warn")
		return
	end

	local strNode
	if node:type() == "string" then
		strNode = node
	elseif node:type():find("^string_") or node:type() == "interpolation" then
		strNode = node:parent()
	elseif node:type() == "escape_sequence" or node:parent():type() == "interpolation" then
		strNode = node:parent():parent()
	else
		u.notify("Not on a triple quoted string.", "warn")
		return
	end

	local text = u.getNodeText(strNode)
	local isMultiline = text:find("[\r\n]")

	-- select `string_content` node, which is the inner docstring
	if scope == "inner" then strNode = strNode:child(1) end

	local startRow, startCol, endRow, endCol = vim.treesitter.get_node_range(strNode)

	-- fix various off-by-ones
	startRow = startRow + 1
	endRow = endRow + 1
	if scope == "outer" or not isMultiline then endCol = endCol - 1 end

	-- multiline-inner: exclude line breaks
	if scope == "inner" and isMultiline then
		startCol = 0
		startRow = startRow + 1
		endRow = endRow - 1
		endCol = #vim.api.nvim_buf_get_lines(0, endRow - 1, endRow, false)[1]
	end

	setSelection({ startRow, startCol }, { endRow, endCol })
end

--------------------------------------------------------------------------------
return M
