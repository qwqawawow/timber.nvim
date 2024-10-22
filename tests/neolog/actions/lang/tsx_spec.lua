local neolog = require("neolog")
local helper = require("tests.neolog.helper")
local actions = require("neolog.actions")

describe("typescriptreact", function()
  before_each(function()
    neolog.setup({
      log_templates = {
        default = {
          tsx = [[console.log("%identifier", %identifier)]],
        },
      },
    })
  end)

  require("tests.neolog.actions.lang.javascript_base")("typescriptreact")
  require("tests.neolog.actions.lang.jsx_base")("typescriptreact")

  it("supports visual selection log", function()
    local input = [[
      function foo() {
        const a = 1
        const b = 1

        return (
          <div>
            <div>{a| + b}</div>
          </div>
        )
      }
    ]]

    local expected = [[
      function foo() {
        const a = 1
        const b = 1

        console.log("a", a)
        console.log("b", b)
        return (
          <div>
            <div>{a + b}</div>
          </div>
        )
      }
    ]]

    helper.assert_scenario({
      input = input,
      filetype = "typescriptreact",
      action = function()
        vim.cmd("normal! vi{")
        actions.insert_log({ position = "above" })
      end,
      expected = expected,
    })

    input = [[
      function foo() {
        const a = 1
        const b = true
        const el = (
          <div>
            {b && <div>{|a + 1}</div>}
            <input className={c} />
          </div>
        )
      }
    ]]

    -- TODO: figure out why indentation is off with inner jsx element
    expected = [[
      function foo() {
        const a = 1
        const b = true
        const el = (
          <div>
          {b && <div>{a + 1}</div>}
          <input className={c} />
          </div>
        )
        console.log("b", b)
        console.log("a", a)
        console.log("c", c)
      }
    ]]

    helper.assert_scenario({
      input = input,
      filetype = "typescriptreact",
      action = function()
        vim.cmd("normal! Vj")
        actions.insert_log({ position = "below" })
      end,
      expected = expected,
    })
  end)
end)
