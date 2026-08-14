-- incenter_core_spec.lua - unit tests for the REAPER-side shared core,
-- run with `busted` against a fake `reaper` API (see spec_helper.lua).

local helper = require("spec_helper")
local load_core = helper.load_core

describe("incenter_core", function()

  describe("shell_quote (POSIX)", function()
    local core = load_core()

    it("wraps a plain string in single quotes", function()
      assert.equal("'abc'", core.shell_quote("abc"))
    end)

    it("escapes embedded single quotes", function()
      assert.equal("'it'\\''s'", core.shell_quote("it's"))
    end)

    it("is inert against shell metacharacters", function()
      local quoted = core.shell_quote("$(rm -rf /); echo `hi` && ok")
      -- everything between the outer quotes stays literal; only a closing
      -- quote followed by the escape idiom would break out, and there is
      -- none here.
      assert.is_nil(quoted:find("^[^']"))
    end)
  end)

  describe("shell_quote (Windows)", function()
    local core = load_core({ GetOS = function() return "Win64" end })

    it("wraps in double quotes", function()
      assert.equal('"abc"', core.shell_quote("abc"))
    end)

    it("escapes embedded double quotes by doubling them", function()
      assert.equal('"say ""hi"""', core.shell_quote('say "hi"'))
    end)
  end)

  describe("split_ext", function()
    local core = load_core()

    it("splits a POSIX path", function()
      local dir, name, ext = core.split_ext("/a/b/c.wav")
      assert.equal("/a/b/", dir)
      assert.equal("c", name)
      assert.equal(".wav", ext)
    end)

    it("splits a bare filename with no directory", function()
      local dir, name, ext = core.split_ext("c.wav")
      assert.equal("", dir)
      assert.equal("c", name)
      assert.equal(".wav", ext)
    end)

    it("handles a name with no extension", function()
      local dir, name, ext = core.split_ext("/a/noext")
      assert.equal("/a/", dir)
      assert.equal("noext", name)
      assert.equal("", ext)
    end)

    it("accepts Windows-style separators even on POSIX", function()
      local dir, name, ext = core.split_ext("C:\\a\\b.wav")
      assert.equal("C:\\a\\", dir)
      assert.equal("b", name)
      assert.equal(".wav", ext)
    end)

    it("keeps only the last extension for multi-dot names", function()
      local _, name, ext = core.split_ext("take.01.wav")
      assert.equal("take.01", name)
      assert.equal(".wav", ext)
    end)
  end)

  describe("basename", function()
    local core = load_core()

    it("strips a POSIX directory", function()
      assert.equal("c.wav", core.basename("/a/b/c.wav"))
    end)

    it("strips a Windows directory", function()
      assert.equal("b.wav", core.basename("C:\\a\\b.wav"))
    end)

    it("returns bare filenames unchanged", function()
      assert.equal("justfile", core.basename("justfile"))
    end)
  end)

  describe("file_exists", function()
    local core = load_core()

    it("is true for a file that exists", function()
      local path = os.tmpname()
      local f = io.open(path, "w"); f:write("x"); f:close()
      assert.is_true(core.file_exists(path))
      os.remove(path)
    end)

    it("is false for a path that doesn't exist", function()
      assert.is_false(core.file_exists("/definitely/not/a/real/path/xyz"))
    end)
  end)

  describe("tmp_path", function()
    local core = load_core()

    it("appends the given suffix", function()
      local p = core.tmp_path(".log")
      assert.truthy(p:match("%.log$"))
    end)

    it("embeds the incenter_ marker", function()
      local p = core.tmp_path(".log")
      assert.truthy(p:match("incenter_"))
    end)

    it("produces different names on successive calls", function()
      local a = core.tmp_path(".log")
      local b = core.tmp_path(".log")
      assert.is_not.equal(a, b)
    end)
  end)

  describe("source_string", function()
    local core = load_core()

    it("uses the (src, buf) -> string shape when available", function()
      local fn = function(_src, _buf) return "picked-buf-shape" end
      assert.equal("picked-buf-shape", core.source_string(fn, "src"))
    end)

    it("falls back to the (src) -> string shape", function()
      local fn = function(src, buf)
        if buf ~= nil then error("does not accept a buffer arg") end
        return "picked-single-shape"
      end
      assert.equal("picked-single-shape", core.source_string(fn, "src"))
    end)

    it("returns empty string when both shapes fail", function()
      local fn = function() error("nope") end
      assert.equal("", core.source_string(fn, "src"))
    end)
  end)

  describe("parse_batch_output", function()
    local core = load_core()

    it("splits OK and ERR lines by input path", function()
      local output = table.concat({
        "some banner text",
        "##OK##\t/a/in.wav\t/a/out.wav",
        "##ERR##\t/b/in.wav\tsomething went wrong",
        "trailing chatter",
      }, "\n")
      local ok_map, err_map = core.parse_batch_output(output)
      assert.equal("/a/out.wav", ok_map["/a/in.wav"])
      assert.equal("something went wrong", err_map["/b/in.wav"])
    end)

    it("captures tabs inside the trailing message", function()
      local output = "##ERR##\t/a/in.wav\tmsg: part1\tpart2"
      local _, err_map = core.parse_batch_output(output)
      assert.equal("msg: part1\tpart2", err_map["/a/in.wav"])
    end)

    it("handles empty output", function()
      local ok_map, err_map, diag_map = core.parse_batch_output("")
      assert.same({}, ok_map)
      assert.same({}, err_map)
      assert.same({}, diag_map)
    end)

    it("captures ##DIAG## lines into a third map, keyed by input path", function()
      local output = table.concat({
        "##DIAG##\t/a/in.wav\toffset=+3.24;attack=48.24;tail=44.10;spread=6.80;win=2048;bands=24",
        "##OK##\t/a/in.wav\t/a/out.wav",
      }, "\n")
      local ok_map, err_map, diag_map = core.parse_batch_output(output)
      assert.equal("/a/out.wav", ok_map["/a/in.wav"])
      assert.same({}, err_map)
      assert.equal(
        "offset=+3.24;attack=48.24;tail=44.10;spread=6.80;win=2048;bands=24",
        diag_map["/a/in.wav"])
    end)
  end)

  describe("format_diag", function()
    local core = load_core()

    it("reports an off-centre measurement with direction words, not signs", function()
      local line = core.format_diag(
        "offset=+3.24;attack=48.24;tail=44.10;spread=6.80;win=2048;bands=24")
      assert.truthy(line:match("right"))
      assert.is_nil(line:match("%+3%.24"))  -- prose uses "right", not a signed number
      assert.truthy(line:match("3%.2"))
      assert.truthy(line:match("48%.2"))
      assert.truthy(line:match("44%.1"))
      assert.truthy(line:match("6%.8"))
      assert.truthy(line:match("2048"))
    end)

    it("uses 'left' for a negative offset", function()
      local line = core.format_diag(
        "offset=-5.00;attack=40.00;tail=44.10;spread=6.80;win=2048;bands=24")
      assert.truthy(line:match("left"))
      assert.is_nil(line:match("right"))
    end)

    it("says plainly the source is already centred below threshold", function()
      local line = core.format_diag(
        "offset=+0.40;attack=45.40;tail=44.90;spread=1.10;win=2048;bands=24")
      assert.truthy(line:match("already centred"))
      assert.truthy(line:match("nothing to correct"))
      assert.is_nil(line:match("right"))
      assert.is_nil(line:match("left"))
    end)

    it("does not call a small measurement a failure", function()
      local line = core.format_diag(
        "offset=+0.10;attack=45.10;tail=45.00;spread=0.50;win=1024;bands=24")
      assert.is_nil(line:lower():match("fail"))
      assert.is_nil(line:lower():match("error"))
    end)

    it("requires BOTH offset and spread under threshold to call it centred", function()
      -- small offset but wide per-band spread: real per-band tilt exists,
      -- must not be reported as "already centred".
      local line = core.format_diag(
        "offset=+0.50;attack=45.50;tail=40.00;spread=5.00;win=2048;bands=24")
      assert.is_nil(line:match("already centred"))
    end)

    it("returns nil for a payload missing required fields", function()
      assert.is_nil(core.format_diag("attack=48.24;win=2048"))
    end)

    it("returns nil for an empty or nil payload", function()
      assert.is_nil(core.format_diag(""))
      assert.is_nil(core.format_diag(nil))
    end)
  end)

  describe("output_dir", function()
    it("prefers the project media directory when one is set", function()
      -- GetProjectPathEx returns the path string directly (pcall adds the
      -- leading call-succeeded boolean); it does not return one itself.
      local core = load_core({
        GetProjectPathEx = function(_proj, _buf) return "/proj/media" end,
      })
      local dir, used_project = core.output_dir("/some/src/file.wav")
      assert.equal("/proj/media/", dir)
      assert.is_true(used_project)
    end)

    it("falls back to the source's own directory with no project path", function()
      local core = load_core({
        GetProjectPathEx = function(_proj, _buf) return "" end,
      })
      local dir, used_project = core.output_dir("/some/src/file.wav")
      assert.equal("/some/src/", dir)
      assert.is_false(used_project)
    end)
  end)

  describe("make_out_path", function()
    local core = load_core()
    local tmp_dir

    before_each(function()
      tmp_dir = os.tmpname()
      os.remove(tmp_dir)
      os.execute("mkdir -p " .. tmp_dir)
      tmp_dir = tmp_dir .. "/"
    end)

    after_each(function()
      os.execute("rm -rf " .. tmp_dir)
    end)

    it("builds a <name>_centered_<stamp>.wav path", function()
      local out = core.make_out_path("/src/take.wav", tmp_dir, "120000")
      assert.equal(tmp_dir .. "take_centered_120000.wav", out)
    end)

    it("dedupes against a file that already exists", function()
      local first = core.make_out_path("/src/take.wav", tmp_dir, "120000")
      local f = io.open(first, "w"); f:write("x"); f:close()

      local second = core.make_out_path("/src/take.wav", tmp_dir, "120000")
      assert.equal(tmp_dir .. "take_centered_120000_2.wav", second)
    end)

    it("dedupes against `allocated`, not just files that exist on disk", function()
      -- Two jobs from the same source in one run both compute their
      -- out_path before either has actually been written, so a disk
      -- check alone can't tell them apart - this is what a caller with
      -- multiple regions from one source file needs.
      local allocated = {}
      local first = core.make_out_path("/src/take.wav", tmp_dir, "120000", allocated)
      allocated[first] = true
      local second = core.make_out_path("/src/take.wav", tmp_dir, "120000", allocated)
      assert.is_not.equal(first, second)
      assert.equal(tmp_dir .. "take_centered_120000_2.wav", second)
    end)
  end)

  describe("find_python", function()
    it("trusts a cached path matching the override without re-probing", function()
      local core = load_core()
      core.__ext_state = nil
      local reaper = _G.reaper
      reaper.SetExtState("incenter", "python_path", "/usr/bin/python3")
      core.python_has_deps = function() error("should not be probed") end

      local path, err = core.find_python("/usr/bin/python3")
      assert.equal("/usr/bin/python3", path)
      assert.is_nil(err)
    end)

    it("trusts a non-empty cache when no override is given", function()
      local core = load_core()
      _G.reaper.SetExtState("incenter", "python_path", "/cached/python3")
      core.python_has_deps = function() error("should not be probed") end

      local path = core.find_python(nil)
      assert.equal("/cached/python3", path)
    end)

    it("scans candidates and caches the first one with deps", function()
      local core = load_core()
      local probed = {}
      core.python_has_deps = function(p)
        probed[#probed + 1] = p
        return p == "/usr/bin/python3"
      end

      local path = core.find_python(nil)
      assert.equal("/usr/bin/python3", path)
      assert.equal("/usr/bin/python3", _G.reaper.GetExtState("incenter", "python_path"))
      assert.is_true(#probed > 0)
    end)

    it("returns an error when no candidate has the deps", function()
      local core = load_core()
      core.python_has_deps = function() return false end

      local path, err = core.find_python(nil)
      assert.is_nil(path)
      assert.truthy(err:match("Found no Python"))
    end)

    it("rejects an override path that doesn't exist on disk", function()
      local core = load_core()
      local path, err = core.find_python("/definitely/not/there/python3")
      assert.is_nil(path)
      assert.truthy(err:match("doesn't exist"))
    end)

    it("rejects an override that exists but lacks numpy/scipy", function()
      local core = load_core()
      local tmp = os.tmpname()
      local f = io.open(tmp, "w"); f:write("x"); f:close()
      core.python_has_deps = function() return false end

      local path, err = core.find_python(tmp)
      assert.is_nil(path)
      assert.truthy(err:match("no numpy/scipy"))
      os.remove(tmp)
    end)

    it("accepts and caches a valid override", function()
      local core = load_core()
      local tmp = os.tmpname()
      local f = io.open(tmp, "w"); f:write("x"); f:close()
      core.python_has_deps = function() return true end

      local path = core.find_python(tmp)
      assert.equal(tmp, path)
      assert.equal(tmp, _G.reaper.GetExtState("incenter", "python_path"))
      os.remove(tmp)
    end)
  end)

  describe("clear_python_cache", function()
    it("removes the cached interpreter path", function()
      local core = load_core()
      _G.reaper.SetExtState("incenter", "python_path", "/some/python3")
      core.clear_python_cache()
      assert.equal("", _G.reaper.GetExtState("incenter", "python_path"))
    end)
  end)

  describe("validate_item", function()
    local function item_with(overrides)
      local src_defaults = {
        kind = "WAV",
        path = "/media/take.wav",
        channels = 2,
      }
      for k, v in pairs(overrides.src or {}) do src_defaults[k] = v end

      -- NB: not `overrides.take_is_nil and nil or {}` -- that idiom
      -- collapses to {} regardless of the condition, since `nil` is falsy
      -- and would trigger the `or` branch too.
      local take = {}
      if overrides.take_is_nil then take = nil end
      local core = load_core({
        GetActiveTake = function(_item) return take end,
        TakeIsMIDI = function(_take) return overrides.is_midi or false end,
        GetMediaItemTake_Source = function(_take)
          if overrides.no_source then return nil end
          return {}
        end,
        GetMediaSourceType = function(_src, _buf) return src_defaults.kind end,
        GetMediaSourceFileName = function(_src, _buf) return src_defaults.path end,
        GetMediaSourceNumChannels = function(_src) return src_defaults.channels end,
      })
      return core
    end

    it("rejects an item with no active take", function()
      local core = item_with({ take_is_nil = true })
      local take, path, reason = core.validate_item({})
      assert.is_nil(take)
      assert.equal("no active take", reason)
    end)

    it("rejects a MIDI take", function()
      local core = item_with({ is_midi = true })
      local _, _, reason = core.validate_item({})
      assert.equal("MIDI take", reason)
    end)

    it("rejects a take with no source", function()
      local core = item_with({ no_source = true })
      local _, _, reason = core.validate_item({})
      assert.equal("no source", reason)
    end)

    it("rejects a SECTION source (reversed/glued)", function()
      local core = item_with({ src = { kind = "SECTION" } })
      local _, _, reason = core.validate_item({})
      assert.truthy(reason:match("SECTION"))
    end)

    it("rejects when the source file isn't readable", function()
      local core = item_with({ src = { path = "/does/not/exist.wav" } })
      local _, _, reason = core.validate_item({})
      assert.equal("source file not readable", reason)
    end)

    it("rejects a non-wav source file", function()
      local tmp = os.tmpname() .. ".aif"
      local f = io.open(tmp, "w"); f:write("x"); f:close()
      local core = item_with({ src = { path = tmp } })
      local _, _, reason = core.validate_item({})
      assert.equal("not a wav file", reason)
      os.remove(tmp)
    end)

    it("rejects a mono wav source", function()
      local tmp = os.tmpname() .. ".wav"
      local f = io.open(tmp, "w"); f:write("x"); f:close()
      local core = item_with({ src = { path = tmp, channels = 1 } })
      local _, _, reason = core.validate_item({})
      assert.equal("not stereo", reason)
      os.remove(tmp)
    end)

    it("accepts a valid stereo wav take", function()
      local tmp = os.tmpname() .. ".wav"
      local f = io.open(tmp, "w"); f:write("x"); f:close()
      local core = item_with({ src = { path = tmp, channels = 2 } })
      local take, path, reason = core.validate_item({})
      assert.is_not_nil(take)
      assert.equal(tmp, path)
      assert.is_nil(reason)
      os.remove(tmp)
    end)
  end)

  describe("get_item_region", function()
    local function core_with(values)
      return load_core({
        GetMediaItemTakeInfo_Value = function(_take, param) return values[param] end,
        GetMediaItemInfo_Value = function(_item, param) return values[param] end,
      })
    end

    it("returns D_STARTOFFS as-is and D_LENGTH*D_PLAYRATE as the region length", function()
      local core = core_with({
        D_STARTOFFS = 12.5, D_LENGTH = 3.0, D_PLAYRATE = 1.0,
      })
      local start_sec, length_sec = core.get_item_region({}, {})
      assert.equal(12.5, start_sec)
      assert.equal(3.0, length_sec)
    end)

    it("scales length by a non-1.0 playrate - the part that's wrong if skipped", function()
      -- A 2x playrate item spanning 1s of timeline covers 2s of source;
      -- using D_LENGTH alone here would silently give the wrong region.
      local core = core_with({
        D_STARTOFFS = 0.0, D_LENGTH = 1.0, D_PLAYRATE = 2.0,
      })
      local _start_sec, length_sec = core.get_item_region({}, {})
      assert.equal(2.0, length_sec)
    end)

    it("scales length by a fractional (slower) playrate too", function()
      local core = core_with({
        D_STARTOFFS = 0.0, D_LENGTH = 1.0, D_PLAYRATE = 0.5,
      })
      local _start_sec, length_sec = core.get_item_region({}, {})
      assert.equal(0.5, length_sec)
    end)

    it("clamps a negative D_STARTOFFS to 0 defensively", function()
      local core = core_with({
        D_STARTOFFS = -2.0, D_LENGTH = 1.0, D_PLAYRATE = 1.0,
      })
      local start_sec = core.get_item_region({}, {})
      assert.equal(0.0, start_sec)
    end)

    it("treats a non-positive playrate as 1.0 defensively", function()
      local core = core_with({
        D_STARTOFFS = 0.0, D_LENGTH = 4.0, D_PLAYRATE = 0.0,
      })
      local _start_sec, length_sec = core.get_item_region({}, {})
      assert.equal(4.0, length_sec)
    end)
  end)

  describe("make_job_key", function()
    local core = load_core()

    it("is stable for identical inputs", function()
      assert.equal(
        core.make_job_key("/a.wav", 1.0, 2.0),
        core.make_job_key("/a.wav", 1.0, 2.0))
    end)

    it("differs when the region differs, same source", function()
      assert.is_not.equal(
        core.make_job_key("/a.wav", 0.0, 1.0),
        core.make_job_key("/a.wav", 5.0, 1.0))
    end)

    it("differs when the source differs, same region", function()
      assert.is_not.equal(
        core.make_job_key("/a.wav", 0.0, 1.0),
        core.make_job_key("/b.wav", 0.0, 1.0))
    end)
  end)

  describe("apply_result", function()
    it("fails when the item no longer validates", function()
      local core = load_core({
        ValidatePtr2 = function(_proj, _obj, kind)
          return kind ~= "MediaItem*"
        end,
      })
      local ok, err = core.apply_result({}, {}, "/out.wav")
      assert.is_false(ok)
      assert.equal("item no longer exists", err)
    end)

    it("fails when the take no longer validates", function()
      local core = load_core({
        ValidatePtr2 = function(_proj, _obj, kind)
          return kind ~= "MediaItem_Take*"
        end,
      })
      local ok, err = core.apply_result({}, {}, "/out.wav")
      assert.is_false(ok)
      assert.equal("take no longer exists", err)
    end)

    it("fails when the corrected file can't be opened", function()
      local core = load_core({
        ValidatePtr2 = function() return true end,
        PCM_Source_CreateFromFile = function(_path) return nil end,
      })
      local ok, err = core.apply_result({}, {}, "/out.wav")
      assert.is_false(ok)
      assert.equal("could not open the corrected file", err)
    end)

    it("repoints the take and rebuilds peaks on success", function()
      local calls = {}
      local core = load_core({
        ValidatePtr2 = function() return true end,
        PCM_Source_CreateFromFile = function(_path) return { tag = "new_source" } end,
        SetMediaItemTake_Source = function(_take, src)
          calls.set_source = src
        end,
        PCM_Source_BuildPeaks = function(_src, stage)
          calls.build_peaks_stage = stage
          if stage == 1 then return 0 end
        end,
        GetSetMediaItemTakeInfo_String = function(_take, field, value, _set)
          calls.name_field = field
          calls.name_value = value
        end,
        SetMediaItemTakeInfo_Value = function(_take, param, value)
          calls.value_param = param
          calls.value_value = value
        end,
        UpdateItemInProject = function(_item)
          calls.updated = true
        end,
      })
      local ok, err = core.apply_result({}, {}, "/out/take_centered_120000.wav")
      assert.is_true(ok)
      assert.is_nil(err)
      assert.same({ tag = "new_source" }, calls.set_source)
      assert.equal("P_NAME", calls.name_field)
      assert.equal("take_centered_120000.wav", calls.name_value)
      -- the part that breaks silently if missed: the new file's sample 0
      -- IS the region's start, so the old D_STARTOFFS must be reset.
      assert.equal("D_STARTOFFS", calls.value_param)
      assert.equal(0.0, calls.value_value)
      assert.is_true(calls.updated)
    end)
  end)

  describe("build_peaks", function()
    it("is a no-op when the binding isn't available", function()
      local core = load_core({ PCM_Source_BuildPeaks = nil })
      assert.has_no.errors(function() core.build_peaks({}) end)
    end)

    it("runs start, poll-until-done, then finish", function()
      local stages = {}
      local poll_count = 0
      local core = load_core({
        PCM_Source_BuildPeaks = function(_src, stage)
          stages[#stages + 1] = stage
          if stage == 1 then
            poll_count = poll_count + 1
            if poll_count >= 3 then return 0 end
            return 1
          end
        end,
      })
      core.build_peaks({})
      assert.equal(0, stages[1])         -- start
      assert.equal(1, stages[#stages - 1]) -- last poll
      assert.equal(2, stages[#stages])   -- finish
      assert.equal(3, poll_count)
    end)

    it("is bounded even if the running flag never clears", function()
      local poll_count = 0
      local core = load_core({
        PCM_Source_BuildPeaks = function(_src, stage)
          if stage == 1 then poll_count = poll_count + 1; return 1 end
        end,
      })
      core.build_peaks({})
      assert.equal(1000, poll_count)
    end)
  end)

  describe("run_worker", function()
    it("captures stdout and a zero exit code", function()
      local core = load_core()
      local ok, output = core.run_worker({ "/bin/echo", "hello there" })
      assert.is_true(ok)
      assert.truthy(output:match("hello there"))
    end)

    it("reports failure for a non-zero exit code", function()
      local core = load_core()
      local ok = core.run_worker({ "/bin/sh", "-c", "exit 3" })
      assert.is_false(ok)
    end)

    it("shell-quotes an argument containing spaces and metacharacters safely", function()
      local core = load_core()
      local ok, output = core.run_worker({ "/bin/echo", "$(touch /tmp/should_not_exist_incenter_test) hi" })
      assert.is_true(ok)
      assert.truthy(output:match("%$%(touch"))
      assert.is_false(core.file_exists("/tmp/should_not_exist_incenter_test"))
    end)
  end)

  describe("run_batch", function()
    -- A realistic run_worker stand-in: reads the manifest core.run_batch
    -- actually wrote and echoes an ##OK## line per entry, using whatever
    -- out_path core.make_out_path really generated - so tests exercise
    -- the real dedup logic instead of a hardcoded filename.
    local function echo_ok_worker(args, _timeout)
      local manifest_path = args[4]
      local mf = io.open(manifest_path, "r")
      local out_lines = {}
      for line in mf:lines() do
        local in_path, out_path = line:match("^([^\t]+)\t([^\t]+)")
        table.insert(out_lines, "##OK##\t" .. out_path .. "\t" .. in_path)
      end
      mf:close()
      return true, table.concat(out_lines, "\n")
    end

    it("maps a successful worker run's OK/ERR lines back by job_key", function()
      local core = load_core()
      local key_a = core.make_job_key("/a.wav", 0.0, 1.0)
      local key_b = core.make_job_key("/b.wav", 0.0, 1.0)
      core.run_worker = function(args, _timeout)
        local mf = io.open(args[4], "r")
        local out_lines = {}
        for line in mf:lines() do
          local in_path, out_path = line:match("^([^\t]+)\t([^\t]+)")
          if in_path == "/a.wav" then
            table.insert(out_lines, "##OK##\t" .. out_path .. "\t" .. in_path)
          else
            table.insert(out_lines, "##ERR##\t" .. out_path .. "\tsomething broke")
          end
        end
        mf:close()
        return true, table.concat(out_lines, "\n")
      end

      local jobs = {
        [key_a] = { src_path = "/a.wav", start_sec = 0.0, length_sec = 1.0 },
        [key_b] = { src_path = "/b.wav", start_sec = 0.0, length_sec = 1.0 },
      }
      local ok_map, err_map = core.run_batch(
        "/usr/bin/python3", "/dsp/incenter.py", jobs,
        { strength = 1.0, tail_strength = 1.0, align = false, verbose = false },
        "/out/"
      )
      assert.truthy(ok_map[key_a])
      assert.truthy(ok_map[key_a]:match("%.wav$"))
      assert.equal("something broke", err_map[key_b])
    end)

    it("marks jobs missing from the output as failed, not silently dropped", function()
      local core = load_core()
      local key_a = core.make_job_key("/a.wav", 0.0, 1.0)
      local key_vanished = core.make_job_key("/vanished.wav", 0.0, 1.0)
      core.run_worker = function(args, _timeout)
        local mf = io.open(args[4], "r")
        local out_lines = {}
        for line in mf:lines() do
          local in_path, out_path = line:match("^([^\t]+)\t([^\t]+)")
          if in_path == "/a.wav" then
            table.insert(out_lines, "##OK##\t" .. out_path .. "\t" .. in_path)
          end
          -- /vanished.wav gets no line - simulates a worker killed mid-batch
        end
        mf:close()
        return true, table.concat(out_lines, "\n")
      end

      local jobs = {
        [key_a] = { src_path = "/a.wav", start_sec = 0.0, length_sec = 1.0 },
        [key_vanished] = { src_path = "/vanished.wav", start_sec = 0.0, length_sec = 1.0 },
      }
      local ok_map, err_map = core.run_batch(
        "/usr/bin/python3", "/dsp/incenter.py", jobs,
        { strength = 1.0, tail_strength = 1.0, align = false, verbose = false },
        "/out/"
      )
      assert.truthy(ok_map[key_a])
      assert.truthy(err_map[key_vanished]:match("no result reported"))
    end)

    it("fails every job and clears the python cache when the worker itself fails", function()
      local core = load_core()
      _G.reaper.SetExtState("incenter", "python_path", "/usr/bin/python3")
      core.run_worker = function(_args, _timeout)
        return false, "traceback...\nModuleNotFoundError: no module named 'scipy'"
      end

      local key_a = core.make_job_key("/a.wav", 0.0, 1.0)
      local key_b = core.make_job_key("/b.wav", 0.0, 1.0)
      local jobs = {
        [key_a] = { src_path = "/a.wav", start_sec = 0.0, length_sec = 1.0 },
        [key_b] = { src_path = "/b.wav", start_sec = 0.0, length_sec = 1.0 },
      }
      local ok_map, err_map = core.run_batch(
        "/usr/bin/python3", "/dsp/incenter.py", jobs,
        { strength = 1.0, tail_strength = 1.0, align = false, verbose = false },
        "/out/"
      )
      assert.same({}, ok_map)
      assert.truthy(err_map[key_a]:match("ModuleNotFoundError"))
      assert.truthy(err_map[key_b]:match("ModuleNotFoundError"))
      assert.equal("", _G.reaper.GetExtState("incenter", "python_path"))
    end)

    it("exposes diag_map as a 4th return value, keyed by job_key", function()
      local core = load_core()
      local key_a = core.make_job_key("/a.wav", 0.0, 1.0)
      core.run_worker = function(args, _timeout)
        local mf = io.open(args[4], "r")
        local in_path, out_path = mf:read("*l"):match("^([^\t]+)\t([^\t]+)")
        mf:close()
        return true, table.concat({
          "##DIAG##\t" .. out_path ..
            "\toffset=+3.24;attack=48.24;tail=44.10;spread=6.80;win=2048;bands=24",
          "##OK##\t" .. out_path .. "\t" .. in_path,
        }, "\n")
      end

      local jobs = { [key_a] = { src_path = "/a.wav", start_sec = 0.0, length_sec = 1.0 } }
      local ok_map, err_map, output, diag_map = core.run_batch(
        "/usr/bin/python3", "/dsp/incenter.py", jobs,
        { strength = 1.0, tail_strength = 1.0, align = false, verbose = false },
        "/out/"
      )
      assert.truthy(ok_map[key_a])
      assert.same({}, err_map)
      assert.is_string(output)
      assert.equal(
        "offset=+3.24;attack=48.24;tail=44.10;spread=6.80;win=2048;bands=24",
        diag_map[key_a])
    end)

    it("still returns a (possibly empty) diag_map when the worker fails", function()
      local core = load_core()
      core.run_worker = function(_args, _timeout)
        return false, "boom"
      end
      local key_a = core.make_job_key("/a.wav", 0.0, 1.0)
      local jobs = { [key_a] = { src_path = "/a.wav", start_sec = 0.0, length_sec = 1.0 } }
      local _ok, _err, _output, diag_map = core.run_batch(
        "/usr/bin/python3", "/dsp/incenter.py", jobs,
        { strength = 1.0, tail_strength = 1.0, align = false, verbose = false },
        "/out/"
      )
      assert.same({}, diag_map)
    end)

    it("writes 4-field manifest lines carrying the job's region", function()
      local core = load_core()
      local captured
      core.run_worker = function(args, _timeout)
        local mf = io.open(args[4], "r")
        captured = mf:read("*a")
        mf:close()
        return true, ""
      end
      local key_a = core.make_job_key("/a.wav", 1.5, 3.25)
      local jobs = { [key_a] = { src_path = "/a.wav", start_sec = 1.5, length_sec = 3.25 } }
      core.run_batch(
        "/usr/bin/python3", "/dsp/incenter.py", jobs,
        { strength = 1.0, tail_strength = 1.0, align = false, verbose = false },
        "/out/"
      )
      local in_path, _out_path, start_str, length_str =
        captured:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\n]+)")
      assert.equal("/a.wav", in_path)
      assert.equal("1.5", start_str)
      assert.equal("3.25", length_str)
    end)

    it("two jobs sharing a source but different regions get distinct output paths", function()
      -- The dedup fix this whole feature depends on: without it, the
      -- second region would silently receive the first one's output.
      local core = load_core()
      core.run_worker = echo_ok_worker

      local key_a = core.make_job_key("/same.wav", 0.0, 1.0)
      local key_b = core.make_job_key("/same.wav", 5.0, 1.0)
      local jobs = {
        [key_a] = { src_path = "/same.wav", start_sec = 0.0, length_sec = 1.0 },
        [key_b] = { src_path = "/same.wav", start_sec = 5.0, length_sec = 1.0 },
      }
      local ok_map = core.run_batch(
        "/usr/bin/python3", "/dsp/incenter.py", jobs,
        { strength = 1.0, tail_strength = 1.0, align = false, verbose = false },
        "/out/"
      )
      assert.truthy(ok_map[key_a])
      assert.truthy(ok_map[key_b])
      assert.is_not.equal(ok_map[key_a], ok_map[key_b])
    end)
  end)

end)
