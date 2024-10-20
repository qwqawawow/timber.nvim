local neolog = require("neolog")
local helper = require("tests.neolog.helper")

describe("typescriptreact", function()
  before_each(function()
    neolog.setup()
  end)

  it("supports jsx expression", function()
    local actions = require("neolog.actions")

    local input = [[
      function foo() {
        const a = 1

        return (
          <div>
            <div>{a| + 1}</div>
          </div>
        )
      }
    ]]

    local expected = [[
      function foo() {
        const a = 1

        console.log("a", a)
        return (
          <div>
            <div>{a + 1}</div>
          </div>
        )
      }
    ]]

    helper.assert_scenario({
      input = input,
      filetype = "typescriptreact",
      action = function()
        actions.add_log({ log_template = [[console.log("%identifier", %identifier)]], position = "above" })
      end,
      expected = expected,
    })

    input = [[
      function foo() {
        const a = 1
        const el = (
          <div>
            <div>{a| + 1}</div>
          </div>
        )
      }
    ]]

    expected = [[
      function foo() {
        const a = 1
        const el = (
          <div>
            <div>{a + 1}</div>
          </div>
        )
        console.log("a", a)
      }
    ]]

    helper.assert_scenario({
      input = input,
      filetype = "typescriptreact",
      action = function()
        actions.add_log({ log_template = [[console.log("%identifier", %identifier)]], position = "below" })
      end,
      expected = expected,
    })
  end)

  it("supports jsx attribute", function()
    local actions = require("neolog.actions")

    local input = [[
      function foo() {
        return (
          <div className={a|}>
            <div>{b + 1}</div>
          </div>
        )
      }
    ]]

    local expected = [[
      function foo() {
        console.log("a", a)
        return (
          <div className={a}>
            <div>{b + 1}</div>
          </div>
        )
      }
    ]]

    helper.assert_scenario({
      input = input,
      filetype = "typescriptreact",
      action = function()
        actions.add_log({ log_template = [[console.log("%identifier", %identifier)]], position = "above" })
      end,
      expected = expected,
    })
  end)

  it("supports visual selection log", function()
    local actions = require("neolog.actions")

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
        actions.add_log({ log_template = [[console.log("%identifier", %identifier)]], position = "above" })
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
        actions.add_log({ log_template = [[console.log("%identifier", %identifier)]], position = "below" })
      end,
      expected = expected,
    })
  end)
end)
