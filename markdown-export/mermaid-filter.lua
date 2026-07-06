-- mermaid-filter.lua
-- Helper module to replace mermaid code blocks with pre-rendered SVG images.

local M = {}

-- We assume svg_map is a table like:
--    = "diagram-1.svg",
--    = "diagram-2.svg",
-- etc.
--
-- We simply replace each mermaid code block in traversal order
-- with the next SVG from the map.

function M.make_mermaid_replacer(svg_map)
  local counter = 0

  return function(el)
    if el.t ~= "CodeBlock" then
      return nil
    end

    -- Pandoc Lua API exposes CodeBlock classes via el.classes.
    -- Keep a fallback for older/internal structures.
    local classes = el.classes
    if classes == nil and el.c and el.c[1] and el.c[1][2] then
      classes = el.c[1][2]
    end
    classes = classes or {}
    local is_mermaid = false
    for _, cls in ipairs(classes) do
      if cls == "mermaid" then
        is_mermaid = true
        break
      end
    end

    if not is_mermaid then
      return nil
    end

    counter = counter + 1
    local svg = svg_map[counter]

    if not svg then
      io.stderr:write("Warning: no SVG mapping for mermaid block #" .. counter .. "\n")
      return nil
    end

    return pandoc.Para({ pandoc.Image({}, svg) })
  end
end

return M