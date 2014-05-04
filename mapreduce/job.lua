local utils = require "mapreduce.utils"

local job = {
  _VERSION = "0.1",
  _NAME = "job",
}

local STATUS = utils.STATUS
local grp_tmp_dir = utils.GRP_TMP_DIR
local serialize_sorted_by_lines = utils.serialize_sorted_by_lines
local gridfs_lines_iterator = utils.gridfs_lines_iterator

-- PRIVATE FUNCTIONS AND METHODS

-- loads the required Lua module, sets the upvalue for the "emit" function,
-- executes init function if needed, and returns the resulting function
local funcs = { }
local function job_get_func(self, fname, args)
  local f = funcs[fname]
  if not f then
    f = { m = require(fname) }
    if f.m.init then f.m.init(args) end
    funcs[fname] = f
    local k,v
    repeat
      k,v = debug.getupvalue (f.m.func, 1)
    until not k or k == "_ENV"
    assert(k == "_ENV")
    -- emit function is inserted in the environment of the function
    f.upvalue = v
  end
  f.upvalue.emit = function(key, value)
    self.result = self.result or {}
    self.result[key] = self.result[key] or {}
    table.insert(self.result[key], value)
  end
  return f.m.func
end

local function job_mark_as_finished(self)
  assert(self.job_tbl)
  local db = self.cnn:connect()
  assert( db:update(self.jobs_ns,
                    {
                      _id = self:get_id(),
                    },
                    {
                      ["$set"] = {
                        status = STATUS.FINISHED,
                        finished_time = os.time(),
                      },
                    },
                    false,
                    false) )
end

function job_mark_as_written(self)
  assert(self.job_tbl)
  local db = self.cnn:connect()
  assert( db:update(self.jobs_ns,
                    {
                      _id = self:get_id(),
                    },
                    {
                      ["$set"] = {
                        status = STATUS.WRITTEN,
                        written_time = os.time(),
                      },
                    },
                    false,
                    false) )
end

-- PUBLIC METHODS

function job:execute()
  return self.fn()
end

function job:get_id()
  assert(self.job_tbl)
  return self.job_tbl._id
end

function job:get_pair()
  assert(self.job_tbl)
  return self.job_tbl._id,self.job_tbl.value
end

function job:status_string()
  return self:get_id()
end

function job:get_results_ns()
  return self.results_ns
end

-- constructor, receives a connection and a task instance
function job:__call(cnn, job_tbl, task_status, fname, args, jobs_ns, results_ns,
                    not_executable, combiner_fname, combiner_args)
  local obj = {
    cnn = cnn,
    job_tbl = job_tbl,
    jobs_ns = jobs_ns,
    results_ns = results_ns,
  }
  setmetatable(obj, { __index=self })
  --
  local fn,g
  if not not_executable then g = job_get_func(obj, fname, args) end
  local key,value = obj:get_pair()
  if task_status == "MAP" then
    obj.results_ns = obj.results_ns .. ".K" .. key
    if not not_executable then
      fn = function()
        g(key,value) -- executes the MAP function, the result is obj.result
        -- the job is marked as finished, but not written
        job_mark_as_finished(obj)
        --
        local results_ns = obj.results_ns
        -- combiner, apply the reduce function before put result to database
        local combiner = (combiner_fname and job_get_func(obj, combiner_fname,
                                                          combiner_args))
        -- aggregates all the map job in a gridfs file, using the combiner
        local result     = obj.result or {}
        local db         = obj.cnn:connect()
        local gridfs     = obj.cnn:gridfs()
        local gridfs_filename = string.format("%s/%s",grp_tmp_dir,results_ns)
        gridfs:remove_file(gridfs_filename)
        local builder=obj.cnn:grid_file_builder()
        serialize_sorted_by_lines(builder,result,combiner)
        builder:build(gridfs_filename)
        -- job is marked as written to the database
        job_mark_as_written(obj)
      end
    end
  elseif task_status == "REDUCE" then
    if not not_executable then
      fn = function()
        -- in reduce jobs, the value is a reference to a gridfs filename
        local part_key = key
        local job_file = value.file
        local res_file = value.result
        local gridfs   = obj.cnn:gridfs()
        local gridfile = gridfs:find_file(res_file)
        local builder  = obj.cnn:grid_file_builder()
        if gridfile then
          for i=1,gridfile:num_chunks() do
            builder:append(gridfile:chunk(i-1):data())
          end
        end
        local counter = 0
        for line in gridfs_lines_iterator(gridfs, job_file) do
          counter = counter + 1
          local k,v = load(line)()
          local v = g(k,v) -- executes the REDUCE function
          assert(v, "Reduce must return a value")
          builder:append(string.format("return %s,%s\n",
                                       utils.escape(k), utils.escape(v)))
          if counter % utils.MAX_IT_WO_CGARBAGE then
            collectgarbage("collect")
          end
        end
        gridfs:remove_file(res_file)
        builder:build(res_file)
        -- job is marked as as written directly
        job_mark_as_written(obj)
      end
    end
  end
  if not_executable then
    fn = function() error("Forbidden execution of jobs here") end
  end
  obj.fn = fn
  return obj
end
setmetatable(job,job)

return job
