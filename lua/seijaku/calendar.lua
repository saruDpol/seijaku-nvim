local M = {}

local month_days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

function M.is_leap_year(year)
  return year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0)
end

function M.days_in_month(year, month)
  if month == 2 and M.is_leap_year(year) then
    return 29
  end

  return month_days[month]
end

function M.is_valid(year, month, day)
  return type(year) == "number"
    and type(month) == "number"
    and type(day) == "number"
    and year >= 1
    and year <= 9999
    and month >= 1
    and month <= 12
    and day >= 1
    and day <= M.days_in_month(year, month)
end

function M.format(year, month, day)
  return string.format("%04d-%02d-%02d", year, month, day)
end

function M.parse(value)
  local year, month, day = tostring(value or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  year, month, day = tonumber(year), tonumber(month), tonumber(day)

  if not M.is_valid(year, month, day) then
    return nil
  end

  return { year = year, month = month, day = day }
end

function M.today()
  return M.parse(os.date("%Y-%m-%d"))
end

-- Proleptic Gregorian calendar conversion based on civil dates. The returned
-- ordinal has an arbitrary epoch; only differences between ordinals matter.
function M.to_ordinal(year, month, day)
  year = year - (month <= 2 and 1 or 0)
  local era = math.floor(year / 400)
  local year_of_era = year - era * 400
  local shifted_month = month + (month > 2 and -3 or 9)
  local day_of_year = math.floor((153 * shifted_month + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365
    + math.floor(year_of_era / 4)
    - math.floor(year_of_era / 100)
    + day_of_year

  return era * 146097 + day_of_era
end

function M.from_ordinal(ordinal)
  local era = math.floor(ordinal / 146097)
  local day_of_era = ordinal - era * 146097
  local year_of_era = math.floor(
    (day_of_era
      - math.floor(day_of_era / 1460)
      + math.floor(day_of_era / 36524)
      - math.floor(day_of_era / 146096))
      / 365
  )
  local year = year_of_era + era * 400
  local day_of_year = day_of_era
    - (365 * year_of_era + math.floor(year_of_era / 4) - math.floor(year_of_era / 100))
  local shifted_month = math.floor((5 * day_of_year + 2) / 153)
  local day = day_of_year - math.floor((153 * shifted_month + 2) / 5) + 1
  local month = shifted_month + (shifted_month < 10 and 3 or -9)
  year = year + (month <= 2 and 1 or 0)

  return { year = year, month = month, day = day }
end

function M.add_days(date, amount)
  local ordinal = M.to_ordinal(date.year, date.month, date.day) + amount
  local result = M.from_ordinal(ordinal)

  if result.year < 1 then
    return { year = 1, month = 1, day = 1 }
  end
  if result.year > 9999 then
    return { year = 9999, month = 12, day = 31 }
  end

  return result
end

function M.add_months(date, amount)
  local month_index = (date.year - 1) * 12 + date.month - 1 + amount
  month_index = math.max(0, math.min(9999 * 12 - 1, month_index))

  local year = math.floor(month_index / 12) + 1
  local month = month_index % 12 + 1
  local day = math.min(date.day, M.days_in_month(year, month))

  return { year = year, month = month, day = day }
end

-- Monday is 1 and Sunday is 7.
function M.weekday(year, month, day)
  local reference = M.to_ordinal(1970, 1, 1)
  return (M.to_ordinal(year, month, day) - reference + 3) % 7 + 1
end

return M
