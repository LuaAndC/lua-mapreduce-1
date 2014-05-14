lua-MapReduce
=============

Lua MapReduce implementation based in MongoDB. It differs from
[ohitjoshi/lua-mapreduce](https://github.com/rohitjoshi/lua-mapreduce)
in the basis of the communication between the processes. In order to
allow fault tolerancy, and to reduce the communication protocol
complexity, this implementation relies on mongoDB. So, all the data
is stored at auxiliary mongoDB collections.

This software depends in:

- [Lua 5.2](http://www.lua.org/)
- [luamongo](https://github.com/moai/luamongo/), mongoDB driver
  for Lua 5.2.

Installation
------------

Copy the `mapreduce` directory to a place visible from your `LUA_PATH`
environment variable. In the same way, in order to test the example, you need to
put the `examples` directory visible through your `LUA_PATH`. It is possible to
add the active directory by writing in the terminal:

```
$ export LUA_PATH='?.lua;?/init.lua'
```

Usage
-----

Two Lua scripts have been prepared for fast running of the software.

- `execute_server.lua` runs the master server for your map-reduce operation.
  Only **one instance** of this script is needed. Note that this software
  receives the **map-reduce task** splitted into several Lua modules. These
  modules had to be visible in the `LUA_PATH` of the server and all the workers
  that you execute. This script receives 7 mandatory arguments:
  
    1. The connection string, normally `localhost` or `localhost:21707`.
    2. The name of the database where the work will be done.
    3. A Lua module which contains the **task** function data.
    4. A Lua module which contains the **map** function data.
    5. A Lua module which contains the **partition** function data.
    6. A Lua module which contains the **reduce** function data.
    7. A Lua module which contains the **final** function data.

- `execute_worker.lua` runs the worker, which is configured by default to
  execute one map-reduce task and finish its operation. One task doesn't mean
  one job. A **map-reduce task** is performed as several individual **map/reduce
  jobs**. A worker waits until all the possible map or reduce jobs are completed
  to consider a task as finished. This script receives two arguments:

    1. The connection string, as above.
    2. The name of the database where the work will be done, as above.

A simple word-count example is available in the repository. There are two
shell-scripts: `execute_server_example.sh` and `execute_worker_example.sh`;
which are ready to run the word-count example in only one machine, with one or
more worker instances. The execution of the example looks like this:

**SERVER**
```
$ ./execute_example_server.sh > output
# Preparing MAP
# MAP execution
 100.0 % 
# Preparing REDUCE
# 	 MERGE AND PARTITIONING
	 100.0 % 
# 	 CREATING JOBS
# 	 STARTING REDUCE
# REDUCE execution
 100.0 % 
# FINAL execution
```

**WORKER**
```
$ ./execute_example_worker.sh 
# NEW TASK READY
# 	 EXECUTING MAP JOB _id: "1"
# 		 FINISHED
# 	 EXECUTING MAP JOB _id: "2"
# 		 FINISHED
# 	 EXECUTING MAP JOB _id: "3"
# 		 FINISHED
# 	 EXECUTING MAP JOB _id: "4"
# 		 FINISHED
# 	 EXECUTING REDUCE JOB _id: "121"
# 		 FINISHED
# 	 EXECUTING REDUCE JOB _id: "37"
# 		 FINISHED
...
```

Map-reduce task example: word-count
-----------------------------------

The example is composed by one Lua module for each of the map-reduce functions,
and are available at the directory `examples/WordCount/`. All the modules has
the same structure, they return a Lua table with two fields:

- **init** function, which receives a table of arguments and allows to configure
  your module options, in case that you need any option.

- A function which implements the necessary Lua code for the operation. The name
  of the function is different for each operation.

A map-reduce task is divided, at least, in the following modules:

- **taskfn.lua** is the script which defines how the data is divided in order to
  create **map jobs**. The **func** field is executed as a Lua *coroutine*, so,
  every map job will be created by calling `corotuine.yield(key,value)`.

```Lua
-- arg is for configuration purposes, it is allowed in any of the scripts
local init = function(arg)
  -- do whatever you need for initialization parametrized by arg table
end
return {
  init = init,
  taskfn = function()
    coroutine.yield(1,"mapreduce/server.lua")
    coroutine.yield(2,"mapreduce/worker.lua")
    coroutine.yield(3,"mapreduce/test.lua")
    coroutine.yield(4,"mapreduce/utils.lua")
  end
}
```

- **mapfn.lua** is the script where the map function is implemented. The
  **func** field is executed as a standard Lua function, and receives three
  arguments `(key,value,emit)`. The first two are generated b
  one of the yields at your `taskfn`
  script. The third argument is a function. Map results
  are produced by calling the function
  `emit(key,value)`.

```Lua
return {
  init = function() end,
  mapfn = function(key,value,emit)
    for line in io.lines(value) do
      for w in line:gmatch("[^%s]+") do
        emit(w,1)
      end
    end
  end
}
```

- **partitionfn.lua** is the script which describes how the map results are
  grouped and partitioned in order to create **reduce jobs**. The **func** field
  is a hash function which receives an emitted key and returns an integer
  number. Depending in your hash function, more or less reducers will be needed.

```Lua
-- string hash function: http://isthe.com/chongo/tech/comp/fnv/
local NUM_REDUCERS = 10
local FNV_prime    = 16777619
local offset_basis = 2166136261
local MAX          = 2^32
return {
  init = function() end,
  partitionfn = function(key)
    -- compute hash
    local h = offset_basis
    for i=1,#key do
      h = (h * FNV_prime) % MAX
      h = bit32.bxor(h, key:byte(i))
    end
    return h % NUM_REDUCERS
  end
}
```
  
- **reducefn.lua** is the script which implements the reduce function. The
  **func** field is a function which receives a pair `(key,values)` where the
  `key` is one of the emitted keys, and the `values` is a Lua array (table with
  integer and sequential keys starting at 1) with all the available map values
  for the given key. The system could reuse the reduce function several times,
  so, it must be idempotent. The reduce results will be grouped following the
  partition function. For each possible partition, a GridFS file will be created
  in a collection called `dbname_fs` where dbname is the database name defined
  above.

```Lua
return {
  init = function() end,
  reducefn = function(key,values)
    local count=0
    for _,v in ipairs(values) do count = count + v end
    return count
  end
}
```

- **finalfn.lua** is the script which implements how to take the results
  produced by the system. The **func** field is a function which receives a
  Lua pairs iterator, and returns a boolean indicating if to destroy or not
  the GridFS collection data. If the returned value is `true`, the results
  will be removed. If the returned value is `false` or `nil`, the results
  will be available after the execution of your map-reduce task.

```Lua
return {
  init = function() end,
  finalfn = function(it)
    for key,value in it do
      print(value,key)
    end
    return true -- indicates to remove mongo gridfs result files
  end
}
```

Performance notes
-----------------

Word-count example using [Europarl v7 English data](http://www.statmt.org/europarl/),
with *1,965,734 lines* and *49,158,635 running words*. The data has been splitted
in 197 files with a maximum of *10,000* lines per file. The task is executed
in *one machine* with *four cores*. The machine runs a MongoDB server, a
lua-mapreduce server and four lua-mapreduce workers. **Note** that this task
is not fair because the data could be stored in the local filesystem.

The output of lua-mapreduce was:

```
$ ./execute_BIG_server.sh  > output
# Iteration 1
# 	 Preparing Map
# 	 Map execution, size= 197
	  100.0 % 
# 	 Preparing Reduce
# 	 Reduce execution, num_files= 1970  size= 10
	  100.0 % 
# 	 Final execution
#   Map sum(cpu_time)    99.278813
#   Reduce sum(cpu_time) 57.789231
# Sum(cpu_time)          157.068044
#   Map real time    42
#   Reduce real time 22
# Real time          64
# Total iteration time 66 seconds
```

**Note:** using only one worker takes: 117 seconds

A naive word-count version implemented with pipes and shellscripts takes:

```
$ time cat /home/experimentos/CORPORA/EUROPARL/en-splits/* | \
  tr ' ' '\n'  | sort | uniq -c > output-pipes
real    2m21.272s
user    2m23.339s
sys     0m2.951s
```

A naive word-count version implemented in Lua takes:

```
$ time cat /home/experimentos/CORPORA/EUROPARL/en-splits/* | \
  lua misc/naive.lua > output-naivetime
real    0m26.125s
user    0m17.458s
sys     0m0.324s
```

Looking to these numbers, it is clear that the better is to work in main memory
and in local storage filesystem, as in the naive Lua implementation, which needs
only 17 seconds (user time), but uses local disk files. The map-reduce approach
takes 64 seconds (real time) with four workers and 146 seconds (user time) with
only one worker. These last two numbers are comparable with the naive
shellscript implementation using pipes, which takes 143 seconds (user
time). Concluding, the preliminar lua-mapreduce implementation, using MongoDB
for communication and GridFS for auxiliary storage, is up to **2** times faster
than a shellscript implementation using pipes. Both implementations sort the
data in order to aggregate the results. In the future, a larger data task will
be choosen to compare this implementation with raw map-reduce in MongoDB and/or
Hadoop.

Last notes
----------

This software is in development. More documentation will be added to the
wiki pages, while we have time to do that. Collaboration is open, and all your
contributions will be welcome.
